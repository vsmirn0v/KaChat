import SwiftUI

/// Kaspa Hub > Chess Online: choose your game. 1v1 or a tournament, each its own screen
/// (`ChessTournamentsView`) with that kind's play tab and leaderboard. If the player is
/// already waiting or playing somewhere, that is offered first.
struct ChessHomeView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var openMode: ChessTournamentsView.Mode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        ChessTabIcon.view(side: 64)
                            .foregroundColor(.accentColor)
                        Text("Choose your game")
                            .font(.title2.weight(.bold))
                        Text("Five minutes a side. Every move is a Kaspa transaction, so every game is on chain for good.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                    if let mine = service.myActiveTournament {
                        Button {
                            openMode = mine.isDuel ? .duel : .tournament
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mine.status == .open ? "hourglass" : "play.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mine.status == .open ? "You're waiting in \(mine.name)" : "You're playing in \(mine.name)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Tap to go back to it").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

                    gameCard(
                        mode: .duel,
                        icon: "person.2.fill",
                        title: "1v1",
                        detail: "Play the next person who joins, or a friend by code. One game, winner takes the leaderboard point."
                    )
                    gameCard(
                        mode: .tournament,
                        icon: "trophy.fill",
                        title: "Tournament",
                        detail: "Eight players, single elimination: quarterfinals, semifinals, final. Public rooms fill as players arrive; private ones by code."
                    )
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Chess Online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
            .navigationDestination(isPresented: Binding(
                get: { openMode != nil },
                set: { if !$0 { openMode = nil } }
            )) {
                if let openMode {
                    ChessTournamentsView(mode: openMode)
                }
            }
            .onAppear { service.acquire() }
            .onDisappear { service.release() }
        }
    }

    private func gameCard(mode: ChessTournamentsView.Mode, icon: String, title: String, detail: String) -> some View {
        Button {
            Haptics.selection()
            openMode = mode
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.scaled(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.bold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
