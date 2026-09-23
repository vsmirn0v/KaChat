import SwiftUI

/// The waiting room: shown full-screen from the moment a player joins a public 1v1 or
/// tournament room until it fills (then the game opens), their seat runs out, or they leave.
/// Nothing else in the app is reachable meanwhile - searching for players is the one thing
/// happening. Your avatar, a question mark for every empty seat (filled in as players arrive),
/// the time your seat is held for, and Leave behind a warning.
struct ChessWaitingRoomView: View {
    let tournamentId: String
    /// The room filled and the game exists: the host opens it and closes this screen.
    let onStarted: (String) -> Void
    /// Left, or the seat ran out: the host closes this screen (with a note when it ran out).
    let onFinished: (_ seatExpired: Bool) -> Void

    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var showLeaveWarning = false
    @State private var isLeaving = false
    @State private var handedOff = false

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text(tournament?.isDuel == true ? "Looking for an opponent" : "Waiting for players")
                    .font(.title2.weight(.bold))
                seats
                countdown
                if let tournament, !tournament.isPublic {
                    privateCode(tournament)
                }
                Text(tournament?.isDuel == true
                     ? "You're paired with the next person who joins. The game starts by itself."
                     : "The tournament starts by itself when all eight seats are taken.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button(role: .destructive) {
                    showLeaveWarning = true
                } label: {
                    Text(isLeaving ? "Leaving…" : "Leave")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
        .alert("Leave the queue?", isPresented: $showLeaveWarning) {
            Button("Leave", role: .destructive) {
                guard let tournament, !isLeaving else { return }
                isLeaving = true
                Task {
                    await service.leave(tournament)
                    isLeaving = false
                    handedOff = true
                    onFinished(false)
                }
            }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Leaving means you will no longer be searching for another player. It is one transaction.")
        }
        .onAppear { service.acquire(); check() }
        .onDisappear { service.release() }
        .onChange(of: tournament?.status) { _ in check() }
        .onChange(of: service.now) { _ in check() }
        .toast(message: service.lastError, style: .error)
    }

    /// Filled, or the seat ran out: hand the screen over. Runs on every tick.
    private func check() {
        guard !handedOff, let tournament, let me else { return }
        if tournament.status == .live || tournament.status == .finished {
            handedOff = true
            onStarted(tournament.id)
        } else if tournament.status == .cancelled || !tournament.isSeated(me, at: service.now) {
            handedOff = true
            onFinished(tournament.status != .cancelled)
        }
    }

    private var seats: some View {
        let capacity = tournament?.capacity ?? 2
        // You first, then the others who are here, then a question mark for each empty seat.
        var shown = tournament?.seatedPlayers(at: service.now) ?? []
        if let me { shown = [me] + shown.filter { $0 != me } }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: capacity == 2 ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(shown, id: \.self) { address in
                seat(address: address, label: ContactsManager.shared.displayName(for: address))
            }
            ForEach(0..<max(0, capacity - shown.count), id: \.self) { _ in
                emptySeat
            }
        }
        .padding(.horizontal, 32)
    }

    private func seat(address: String, label: String) -> some View {
        VStack(spacing: 8) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: label,
                size: 64,
                contactAddress: address
            )
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var emptySeat: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .frame(width: 64, height: 64)
                .overlay(
                    Text("?")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                )
            Text("Waiting")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func privateCode(_ tournament: ChessTournament) -> some View {
        VStack(spacing: 6) {
            Text("Share this code")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Text(tournament.id)
                    .font(.title3.monospaced().weight(.semibold))
                Button {
                    UIPasteboard.general.string = tournament.id
                    Haptics.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                ShareLink(item: "Play me at chess in KaChat: open Kaspa Hub > Chess > \(tournament.isDuel ? "1v1" : "Tournaments") > Join with a code, and enter \(tournament.id)") {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private var countdown: some View {
        let expiry = me.flatMap { tournament?.seatExpiry(of: $0) } ?? service.now
        let left = max(0, Int((expiry - service.now) / 1000))
        return VStack(spacing: 4) {
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(left < 30 ? .red : .primary)
            Text("Your seat is held this long. If no one joins in time, you leave the queue.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
