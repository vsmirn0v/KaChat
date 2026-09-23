import SwiftUI

/// Chess Online > 1v1 or Tournaments: one kind of game per screen, chosen on ChessHomeView.
/// Two tabs in the app's underline style: the play tab (a public room that pairs the next
/// joiners or fills to eight, plus private games by code) and that kind's leaderboard. Every
/// row reads from `ChessTournamentService`, which reduces the arena the moment a screen here is up.
struct ChessTournamentsView: View {
    /// Which game: also the name of the play tab.
    enum Mode: String, CaseIterable, Identifiable {
        case duel = "1v1"
        case tournament = "Tournaments"
        var id: String { rawValue }
    }
    enum Tab: CaseIterable { case play, activeGames, finished, leaderboard }
    /// Both screens: play, Active (watch-only), Finished, Leaderboard.
    private var tabs: [Tab] { [.play, .activeGames, .finished, .leaderboard] }

    /// Fixed for the screen's life: this is the 1v1 screen or the Tournaments screen.
    let mode: Mode

    @ObservedObject private var service = ChessTournamentService.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var tab: Tab = .play
    @State private var showCreate = false
    @State private var newName = ""
    @State private var creatorCode = ""
    @State private var isCreating = false
    @State private var showJoinPrivate = false
    @State private var privateCode = ""
    @State private var isJoining = false
    @State private var openTournamentId: String?
    /// A game opened straight from Active games, to watch.
    @State private var watchGame: (tournament: String, game: String)?
    /// The waiting room on screen (full-screen, nothing else reachable) - see ChessWaitingRoomView.
    @State private var waitingRoomId: String?
    @State private var waitingNotice: String?

    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        VStack(spacing: 0) {
            // The same underline tab bar the Chats screen uses (see chatsTopTabBar there),
            // so a tab is a tab wherever it appears in the app.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.self) { tabButton($0) }
                }
                Divider()
            }
            .contentShape(Rectangle())
            .gesture(tabSwipe())
            List {
                switch tab {
                case .play:
                    if mode == .duel { duelSections } else { tournamentSections }
                case .activeGames:
                    activeGamesSection
                case .finished:
                    finishedSection
                case .leaderboard:
                    ChessLeaderboardRows(mode: mode)
                }
            }
            .listStyle(.insetGrouped)
            .gesture(tabSwipe())
        }
        .navigationTitle(mode.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        .navigationDestination(isPresented: Binding(
            get: { openTournamentId != nil },
            set: { if !$0 { openTournamentId = nil } }
        )) {
            if let id = openTournamentId {
                ChessTournamentView(tournamentId: id)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { watchGame != nil },
            set: { if !$0 { watchGame = nil } }
        )) {
            if let watchGame {
                ChessTournamentGameView(tournamentId: watchGame.tournament, gameId: watchGame.game)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { waitingRoomId != nil },
            set: { if !$0 { waitingRoomId = nil } }
        )) {
            if let id = waitingRoomId {
                ChessWaitingRoomView(
                    tournamentId: id,
                    onStarted: { started in
                        waitingRoomId = nil
                        // The tournament screen opens the player's game the moment it exists.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openTournamentId = started }
                    },
                    onFinished: { expired in
                        waitingRoomId = nil
                        if expired { waitingNotice = "No one joined in time. You're out of the queue - join again whenever you like." }
                    }
                )
                .environmentObject(walletManager)
            }
        }
        .toast(message: waitingNotice, style: .error)
        // Back on this screen with a live seat (a relaunch, a tap on a public room card):
        // the waiting room is the only place to be.
        .onChange(of: service.myActiveTournament?.id) { _ in showWaitingRoomIfSeated() }
        .onAppear { showWaitingRoomIfSeated() }
        .alert(mode == .duel ? "Create a private 1v1" : "Create a private tournament", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            if mode == .tournament {
                TextField("Creator code", text: $creatorCode)
            }
            Button("Cancel", role: .cancel) {}
            Button(isCreating ? "Creating…" : "Create") {
                guard !isCreating else { return }
                isCreating = true
                let asDuel = mode == .duel
                Task {
                    let id = asDuel
                        ? await service.createPrivateDuel(named: newName)
                        : await service.createPrivateTournament(named: newName, code: creatorCode)
                    // The creator holds the first seat: straight into the waiting room.
                    if let id { waitingRoomId = id }
                    isCreating = false
                }
            }
        } message: {
            Text(mode == .duel
                 ? "You get a code to share with the person you want to play. The game starts when they join. Creating it is one transaction."
                 : "You take the first seat and get a code to share. It starts when eight players have joined. Creating it is one transaction.")
        }
        .alert("Join with a code", isPresented: $showJoinPrivate) {
            TextField("Code", text: $privateCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(isJoining ? "Joining…" : "Join") {
                guard !isJoining else { return }
                isJoining = true
                Task {
                    if await service.joinPrivate(code: privateCode) {
                        waitingRoomId = privateCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                    isJoining = false
                }
            }
        } message: {
            Text("The eight-character code the creator shared. Joining is one transaction (fee: \(service.feeText(for: ChessTournamentCodec.join(id: "abcdefgh")) ?? "--")).")
        }
        .toast(message: service.lastError, style: .error)
        .onAppear { service.acquire() }
        .onDisappear { service.release() }
    }

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .play: return mode.rawValue
        case .activeGames: return "Active"
        case .finished: return "Finished"
        case .leaderboard: return "Leaderboard"
        }
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = self.tab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { self.tab = tab }
        } label: {
            VStack(spacing: 8) {
                Text(tabTitle(tab))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
    }

    /// Swipe between the two tabs, as on the Chats screen.
    private func tabSwipe() -> some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .global)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    guard let index = tabs.firstIndex(of: tab) else { return }
                    if dx < 0, index + 1 < tabs.count { tab = tabs[index + 1] }
                    else if dx > 0, index > 0 { tab = tabs[index - 1] }
                }
            }
    }

    private func showWaitingRoomIfSeated() {
        guard let mine = service.myActiveTournament, mine.status == .open, let me,
              mine.isSeated(me, at: service.now) else { return }
        if waitingRoomId != mine.id { waitingRoomId = mine.id }
    }

    // MARK: - 1v1

    @ViewBuilder
    private var duelSections: some View {
        Section {
            publicRoomCard(room: service.currentDuelRoom, id: service.currentDuelRoomId,
                           title: "Public 1v1 #\(ChessTournamentCodec.duelNumber(of: service.currentDuelRoomId) ?? 1)",
                           capacity: 2) { await service.joinPublicDuelQueue() }
        } header: {
            Text("Public")
        } footer: {
            Text("Join and you are paired with the next person who joins. When a room fills, the game starts and the next room opens. Five minutes a side; every move is a Kaspa transaction (about 0.0017 KAS each). Games here count on the leaderboard.")
        }
        Section {
            ForEach(service.myPrivateDuels) { duel in
                tournamentRow(duel, action: duel.status == .open ? "Waiting" : "In play")
            }
            Button {
                privateCode = ""
                showJoinPrivate = true
            } label: {
                Label("Join with a code", systemImage: "key")
            }
            Button {
                newName = ""
                showCreate = true
            } label: {
                Label("Create a private 1v1", systemImage: "plus.circle")
            }
        } header: {
            Text("Private")
        } footer: {
            Text("Play a friend: create a 1v1, share its code. Private 1v1s count on the leaderboard too.")
        }
    }

    // MARK: - Finished

    /// Every public game of this kind that has ended, newest first - the result on the row,
    /// the board (and its chat) a tap away.
    @ViewBuilder
    private var finishedSection: some View {
        let done = Array(service.finishedTournaments.filter { $0.isDuel == (mode == .duel) && $0.isPublic }.prefix(100))
        Section {
            if done.isEmpty {
                Text(mode == .duel ? "No finished 1v1 games yet." : "No finished tournaments yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(done) { tournamentRow($0, action: $0.champion.map { "Won by \(name(for: $0))" } ?? "Finished") }
        } header: {
            Text(mode == .duel ? "Finished 1v1 games" : "Finished tournaments")
        }
    }

    // MARK: - Active games (watch only)

    /// Every public game of this kind being played right now, for anyone to watch - board and
    /// clocks live, no chat, no moves (the game screen keeps its composer for the two players).
    /// 1v1: one row per game. Tournaments: a section per tournament, a row per game in play,
    /// and the bracket a tap away.
    @ViewBuilder
    private var activeGamesSection: some View {
        let live = service.liveTournaments.filter { $0.isDuel == (mode == .duel) && $0.isPublic }
        if live.isEmpty {
            Section {
                Text(mode == .duel
                     ? "No 1v1 games are being played right now. When one starts, it shows up here to watch."
                     : "No tournament is being played right now. When one starts, its games show up here to watch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } header: {
                Text("Live now")
            }
        } else if mode == .duel {
            Section {
                ForEach(live) { duel in
                    if let game = duel.games.values.first {
                        liveGameRow(game, in: duel)
                    }
                }
            } header: {
                Text("Live now")
            } footer: {
                Text("Watching is free - nothing is sent. Only the two players can move or chat.")
            }
        } else {
            ForEach(live) { tournament in
                Section {
                    let games = tournament.games.values.filter { !$0.isOver }.sorted { ($0.round, $0.id) < ($1.round, $1.id) }
                    ForEach(games) { game in
                        liveGameRow(game, in: tournament)
                    }
                    tournamentRow(tournament, action: "Bracket")
                } header: {
                    Text(tournament.name)
                }
            }
        }
    }

    private func liveGameRow(_ game: ChessTournamentGame, in tournament: ChessTournament) -> some View {
        Button {
            watchGame = (tournament.id, game.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(for: game.white)).fontWeight(.semibold)
                        Text("vs").foregroundColor(.secondary)
                        Text(name(for: game.black)).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    Text((tournament.isDuel ? tournament.name : (game.round == 3 ? "Final" : (game.round == 2 ? "Semifinal" : "Round 1")))
                         + " · move \(game.moves.count / 2 + 1) · \(game.sideToMove == .white ? "white" : "black") to move")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(clockText(game.remainingMs(game.sideToMove, at: service.now)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(.secondary)
                Text("Watch")
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

    private func clockText(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Tournaments

    @ViewBuilder
    private var tournamentSections: some View {
        Section {
            publicRoomCard(room: service.currentPublicRoom, id: service.currentPublicRoomId,
                           title: "Public tournament #\(ChessTournamentCodec.publicNumber(of: service.currentPublicRoomId) ?? 1)",
                           capacity: ChessTournamentCodec.playerCount) { await service.joinPublicQueue() }
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
    }

    // MARK: - Shared pieces

    /// The one public room taking players: its seats, and Join - or where you already are.
    private func publicRoomCard(room: ChessTournament?, id: String, title: String, capacity: Int, join: @escaping () async -> Void) -> some View {
        let seated = room?.seatedPlayers(at: service.now) ?? []
        let count = seated.count
        let inThisRoom = me.map { seated.contains($0) } ?? false
        let busyElsewhere = service.myActiveTournament != nil && !inThisRoom
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: capacity == 2 ? "person.2.fill" : "person.3.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text("\(count) of \(capacity) player\(capacity == 1 ? "" : "s") waiting").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(0..<capacity, id: \.self) { seat in
                    Circle()
                        .fill(seat < count ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 12, height: 12)
                }
            }
            if inThisRoom, let room {
                pill("You're in. Waiting for \(max(0, capacity - count)) more…", filled: false) { waitingRoomId = room.id }
            } else if let mine = service.myActiveTournament, busyElsewhere {
                pill(mine.status == .open ? "You're waiting in \(mine.name)" : "You're playing in \(mine.name)", filled: false) {
                    if mine.status == .open { waitingRoomId = mine.id } else { openTournamentId = mine.id }
                }
            } else {
                pill(isJoining ? "Joining…" : (service.historyReady ? service.joinLabel(roomId: id) : "Loading rooms…"), filled: service.historyReady) {
                    guard !isJoining, service.historyReady else { return }
                    Haptics.impact(.light)
                    isJoining = true
                    Task {
                        await join()
                        isJoining = false
                        // Into the waiting room as soon as the seat is ours on chain.
                        showWaitingRoomIfSeated()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pill(_ text: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(filled ? Color.accentColor : Color.accentColor.opacity(0.15))
                .foregroundColor(filled ? .white : .accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Contact name, then KNS domain, then the shortened address - for the player too.
    private func name(for address: String) -> String {
        ContactsManager.shared.displayName(for: address)
    }

    private func tournamentRow(_ tournament: ChessTournament, action: String) -> some View {
        Button {
            openTournamentId = tournament.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tournament.status == .finished ? "trophy.fill" : (tournament.isPublic ? (tournament.isDuel ? "person.2.fill" : "person.3.fill") : "lock.fill"))
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tournament.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(tournament.players.count) of \(tournament.capacity) players" + (tournament.isPublic ? "" : " · code \(tournament.id)"))
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

/// One kind's leaderboard, as rows inside the screen's list: 1v1 (wins and losses in 1v1
/// games) or Tournaments (tournaments won, then the wins and losses inside them). What the
/// phone has read; the indexer's version (CHESS_TOURNAMENTS.md §6) will cover all history.
struct ChessLeaderboardRows: View {
    let mode: ChessTournamentsView.Mode
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager

    private var rows: [ChessLeaderboardRow] {
        mode == .duel
            ? ChessTournamentEngine.duelLeaderboard(service.leaderboard)
            : ChessTournamentEngine.tournamentLeaderboard(service.leaderboard)
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(mode == .duel ? "No finished 1v1 games yet." : "No finished tournaments yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
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
                    Text(ContactsManager.shared.displayName(for: row.address))
                        .font(.subheadline.weight(row.address == walletManager.currentWallet?.publicAddress ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if mode == .duel {
                        HStack(spacing: 10) {
                            Text("\(row.duelWins) W").foregroundColor(.green)
                            Text("\(row.duelLosses) L").foregroundColor(.red)
                        }
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label("\(row.tournamentsWon)", systemImage: "trophy.fill")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundColor(.yellow)
                            HStack(spacing: 8) {
                                Text("\(row.tournamentGameWins) W").foregroundColor(.green)
                                Text("\(row.tournamentGameLosses) L").foregroundColor(.red)
                            }
                            .font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }
                }
                .listRowBackground(row.address == walletManager.currentWallet?.publicAddress ? Color.accentColor.opacity(0.12) : nil)
            }
        } header: {
            Text(mode == .duel ? "1v1 leaderboard · most wins, fewest losses" : "Tournament leaderboard · most tournaments won")
        }
    }
}
