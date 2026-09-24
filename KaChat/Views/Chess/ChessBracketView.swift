import SwiftUI

/// The tournament as a bracket - quarterfinals, semifinals, final, champion - with the pairs
/// joined by lines, every game a card you can tap to watch. Live games carry a LIVE pill and
/// the running clock; finished ones mark the winner; a pair not yet decided shows who it is
/// waiting on. Your own games get the accent border.
struct ChessBracketView: View {
    let tournament: ChessTournament
    let me: String?
    let now: Int64
    let onOpenGame: (String) -> Void

    private static let cardWidth: CGFloat = 164
    private static let cardHeight: CGFloat = 66
    private static let rowGap: CGFloat = 14
    private static let columnGap: CGFloat = 40
    private static let labelHeight: CGFloat = 26

    private var columnX: [CGFloat] { (0..<4).map { CGFloat($0) * (Self.cardWidth + Self.columnGap) } }
    private var round1Y: [CGFloat] { (0..<4).map { CGFloat($0) * (Self.cardHeight + Self.rowGap) } }
    private var semiY: [CGFloat] { [midpoint(round1Y[0], round1Y[1]), midpoint(round1Y[2], round1Y[3])] }
    private var finalY: CGFloat { midpoint(semiY[0], semiY[1]) }
    private func midpoint(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 }
    private var contentHeight: CGFloat { round1Y[3] + Self.cardHeight }
    private var contentWidth: CGFloat { columnX[3] + Self.cardWidth }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(["Quarterfinals", "Semifinals", "Final", "Champion"].enumerated()), id: \.offset) { index, title in
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .frame(width: Self.cardWidth, alignment: .leading)
                        if index < 3 { Spacer().frame(width: Self.columnGap) }
                    }
                }
                .frame(height: Self.labelHeight)
                ZStack(alignment: .topLeading) {
                    connectors
                    ForEach(0..<4, id: \.self) { index in
                        matchCard(gameId: "1-\(index)", placeholder: ("Seed \(seedPair(index).0)", "Seed \(seedPair(index).1)"))
                            .offset(x: columnX[0], y: round1Y[index])
                    }
                    ForEach(0..<2, id: \.self) { index in
                        matchCard(gameId: "2-\(index)", placeholder: ("Winner of QF\(index * 2 + 1)", "Winner of QF\(index * 2 + 2)"))
                            .offset(x: columnX[1], y: semiY[index])
                    }
                    matchCard(gameId: "3-0", placeholder: ("Winner of SF1", "Winner of SF2"))
                        .offset(x: columnX[2], y: finalY)
                    championCard
                        .offset(x: columnX[3], y: finalY)
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .padding(16)
        }
    }

    /// Round 1 pairs by seed: 1v8, 2v7, 3v6, 4v5.
    private func seedPair(_ index: Int) -> (Int, Int) { (index + 1, 8 - index) }

    // MARK: - Lines

    private var connectors: some View {
        Path { path in
            let w = Self.cardWidth, h = Self.cardHeight / 2, gap = Self.columnGap / 2
            func join(fromX: CGFloat, fromYs: [CGFloat], toX: CGFloat, toY: CGFloat) {
                for y in fromYs {
                    path.move(to: CGPoint(x: fromX + w, y: y + h))
                    path.addLine(to: CGPoint(x: fromX + w + gap, y: y + h))
                    path.addLine(to: CGPoint(x: fromX + w + gap, y: toY + h))
                }
                path.move(to: CGPoint(x: fromX + w + gap, y: toY + h))
                path.addLine(to: CGPoint(x: toX, y: toY + h))
            }
            join(fromX: columnX[0], fromYs: [round1Y[0], round1Y[1]], toX: columnX[1], toY: semiY[0])
            join(fromX: columnX[0], fromYs: [round1Y[2], round1Y[3]], toX: columnX[1], toY: semiY[1])
            join(fromX: columnX[1], fromYs: [semiY[0], semiY[1]], toX: columnX[2], toY: finalY)
            join(fromX: columnX[2], fromYs: [finalY], toX: columnX[3], toY: finalY)
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Cards

    private func matchCard(gameId: String, placeholder: (String, String)) -> some View {
        let game = tournament.games[gameId]
        let mine = game.map { me != nil && ($0.white == me || $0.black == me) } ?? false
        return Button {
            if let game { onOpenGame(game.id) }
        } label: {
            VStack(spacing: 0) {
                if let game {
                    playerRow(address: game.white, game: game)
                    Divider().padding(.horizontal, 8)
                    playerRow(address: game.black, game: game)
                } else {
                    placeholderRow(placeholder.0)
                    Divider().padding(.horizontal, 8)
                    placeholderRow(placeholder.1)
                }
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(mine ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: mine ? 1.6 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if let game { statusPill(game) }
            }
        }
        .buttonStyle(.plain)
        .disabled(game == nil)
    }

    private func playerRow(address: String, game: ChessTournamentGame) -> some View {
        let isWinner = game.winner == address
        let isLoser = game.isOver && game.winner != nil && !isWinner
        let toMove = !game.isOver && game.address(of: game.sideToMove) == address
        return HStack(spacing: 6) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: address),
                size: 20,
                contactAddress: address
            )
            Text(ContactsManager.shared.displayName(for: address))
                .font(.caption.weight(isWinner ? .bold : .semibold))
                .lineLimit(1)
                .foregroundColor(isLoser ? .secondary : .primary)
            Spacer(minLength: 2)
            if isWinner {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            } else if toMove {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.cardHeight / 2 - 0.5)
        .opacity(isLoser ? 0.55 : 1)
    }

    private func placeholderRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 20, height: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.cardHeight / 2 - 0.5)
    }

    @ViewBuilder
    private func statusPill(_ game: ChessTournamentGame) -> some View {
        if !game.isOver {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                Text("LIVE " + clockText(game.remainingMs(game.sideToMove, at: now)))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .offset(x: -6, y: -8)
        }
    }

    private var championCard: some View {
        let champion = tournament.champion
        return HStack(spacing: 8) {
            if let champion {
                KNSAvatarView(
                    avatarURLString: KNSService.shared.profileCache[champion]?.avatarURL,
                    fallbackText: ContactsManager.shared.displayName(for: champion),
                    size: 28,
                    contactAddress: champion
                )
                VStack(alignment: .leading, spacing: 2) {
                    Label("Champion", systemImage: "trophy.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.yellow)
                    Text(ContactsManager.shared.displayName(for: champion))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "trophy")
                    .font(.title3)
                    .foregroundColor(.yellow.opacity(0.7))
                Text("To be decided")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(champion == nil ? 0.06 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
    }

    private func clockText(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
