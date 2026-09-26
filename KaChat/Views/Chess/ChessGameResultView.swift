import SwiftUI

/// The moment a game ends, over the board: a burst for the winner, a quiet card for the loser,
/// a plain one for anyone watching. It stays about two seconds and the result screen follows.
struct ChessGameEndOverlay: View {
    let winnerName: String
    let outcome: ChessTournamentGame.Outcome
    /// nil for a spectator.
    let iWon: Bool?

    @State private var appeared = false
    @State private var burst = false

    private var headline: String {
        switch iWon {
        case .some(true): return "You won!"
        case .some(false): return "You lost"
        case .none: return "\(winnerName) won"
        }
    }

    private var detail: String {
        switch outcome {
        case .checkmate: return "Checkmate"
        case .resignation: return "By resignation"
        case .timeout: return "On time"
        case .drawTiebreak(let reason): return "Draw by \(reason) - won on clock"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if iWon == true {
                // Sparks flying out from the middle - a real burst, not a static badge.
                ForEach(0..<18, id: \.self) { i in
                    let angle = Double(i) / 18 * 2 * .pi
                    let distance: CGFloat = burst ? 150 : 0
                    Text(["✨", "🎉", "⭐", "🎊", "💫"][i % 5])
                        .font(.scaled(size: i.isMultiple(of: 3) ? 26 : 18))
                        .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                        .opacity(burst ? 0 : 1)
                        .animation(.easeOut(duration: 1.1).delay(0.15), value: burst)
                }
            }
            VStack(spacing: 8) {
                Image(systemName: iWon == true ? "trophy.fill" : (iWon == false ? "flag.fill" : "checkmark.seal.fill"))
                    .font(.scaled(size: 54))
                    .foregroundColor(iWon == true ? .yellow : .white)
                    .shadow(color: iWon == true ? .yellow.opacity(0.8) : .clear, radius: 18)
                Text(headline)
                    .font(.scaled(size: 34, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .scaleEffect(appeared ? 1 : 0.4)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: appeared)
        }
        .onAppear {
            appeared = true
            burst = true
            if iWon == true { Haptics.success() } else if iWon == false { Haptics.error() }
        }
    }
}

/// After a game: the player's record on the board this game counts on (1v1 or Tournaments),
/// with the change this game made, and the top of that board around them.
struct ChessGameResultView: View {
    let tournamentId: String
    let gameId: String
    /// The player's record before this game landed - what the screen counts up from.
    let before: ChessLeaderboardRow?
    let onDone: () -> Void

    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var revealed = false
    /// A tapped leaderboard row: the same User Info sheet as everywhere else.
    @State private var profileContact: Contact?

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var game: ChessTournamentGame? { tournament?.games[gameId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }
    private var isDuel: Bool { tournament?.isDuel ?? true }
    private var board: [ChessLeaderboardRow] {
        isDuel ? ChessTournamentEngine.duelLeaderboard(service.leaderboard) : ChessTournamentEngine.tournamentLeaderboard(service.leaderboard)
    }
    private var mine: ChessLeaderboardRow? { board.first { $0.address == me } }
    private var rank: Int? { board.firstIndex { $0.address == me }.map { $0 + 1 } }
    private var iWon: Bool { game?.winner == me }

    /// 1v1: games won and lost. Tournaments: whole tournaments won (champion) and lost
    /// (knocked out) - a game won inside a tournament is not a score, and this screen is
    /// never shown for one (the player goes to the bracket instead).
    private func wins(_ row: ChessLeaderboardRow?) -> Int { isDuel ? (row?.wins ?? 0) : (row?.tournamentsWon ?? 0) }
    private func losses(_ row: ChessLeaderboardRow?) -> Int { isDuel ? (row?.losses ?? 0) : (row?.tournamentsLost ?? 0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Image(systemName: iWon ? "trophy.fill" : "flag.fill")
                            .font(.scaled(size: 44))
                            .foregroundColor(iWon ? .yellow : .secondary)
                        Text(iWon ? "Victory" : "Defeat")
                            .font(.largeTitle.weight(.heavy))
                        if let game, let winner = game.winner {
                            Text(outcomeText(game, winner: winner))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 24)

                    // The record: before -> after, on the board this game counts on.
                    VStack(spacing: 10) {
                        Text(isDuel ? "Your 1v1 record" : "Your tournament record")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        HStack(spacing: 28) {
                            stat("Wins", value: revealed ? wins(mine) : wins(before), delta: iWon ? 1 : 0, color: .green)
                            ratio
                            stat("Losses", value: revealed ? losses(mine) : losses(before), delta: iWon ? 0 : 1, color: .red)
                        }
                        if let rank {
                            Text("#\(rank) on the \(isDuel ? "1v1" : "tournament") board")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .padding(.horizontal, 16)

                    if let tournament, !tournament.isDuel {
                        Text(iWon
                             ? (tournament.status == .finished ? "You won the tournament." : "You go through to the next round. Your next game opens by itself when your opponent is decided.")
                             : "You are out of this tournament. You can watch the rest of the bracket.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    leaderboardTop
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(isDuel ? "1v1" : "Tournament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone() } }
            }
        }
        .onAppear {
            service.acquire()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { revealed = true }
            }
        }
        .onDisappear { service.release() }
    }

    private func stat(_ label: String, value: Int, delta: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.scaled(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(delta > 0 ? "+\(delta)" : " ")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundColor(color)
                .opacity(revealed && delta > 0 ? 1 : 0)
        }
    }

    private var ratio: some View {
        let w = revealed ? wins(mine) : wins(before)
        let l = revealed ? losses(mine) : losses(before)
        let text = w + l == 0 ? "-" : String(format: "%.0f%%", Double(w) / Double(w + l) * 100)
        return VStack(spacing: 2) {
            Text(text)
                .font(.scaled(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("Win rate").font(.caption).foregroundColor(.secondary)
        }
    }

    private var leaderboardTop: some View {
        let top = Array(board.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            Text(isDuel ? "1v1 leaderboard" : "Tournament leaderboard")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                Button {
                    let contacts = ContactsManager.shared
                    profileContact = contacts.getContact(byAddress: row.address) ?? contacts.getOrCreateContact(address: row.address)
                } label: {
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    KNSAvatarView(
                        avatarURLString: KNSService.shared.profileCache[row.address]?.avatarURL,
                        fallbackText: ContactsManager.shared.displayName(for: row.address),
                        size: 32,
                        contactAddress: row.address
                    )
                    Text(ContactsManager.shared.displayName(for: row.address))
                        .font(.subheadline.weight(row.address == me ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if isDuel {
                        Text("\(row.wins) W  \(row.losses) L")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    } else {
                        Label("\(row.tournamentsWon)", systemImage: "trophy.fill")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundColor(.yellow)
                        Text("\(row.tournamentsLost) L")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(row.address == me ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: Binding(
            get: { profileContact != nil },
            set: { if !$0 { profileContact = nil } }
        )) {
            if let contact = profileContact {
                NavigationStack {
                    ChatInfoView(
                        contact: Binding(
                            get: { profileContact ?? contact },
                            set: { profileContact = $0 }
                        ),
                        title: "User Info",
                        showsNotificationSettings: false
                    )
                }
            }
        }
    }

    private func outcomeText(_ game: ChessTournamentGame, winner: String) -> String {
        let who = ContactsManager.shared.displayName(for: winner)
        switch game.outcome {
        case .checkmate: return "Checkmate. \(who) won."
        case .resignation: return "\(who) won by resignation."
        case .timeout: return "\(who) won on time."
        case .drawTiebreak(let reason): return "Draw by \(reason). \(who) won on clock."
        case .none: return ""
        }
    }
}
