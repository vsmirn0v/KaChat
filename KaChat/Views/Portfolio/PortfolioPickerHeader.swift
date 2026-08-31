import SwiftUI

/// Per-card display data for the portfolio picker header — computed fresh from
/// `PortfolioViewModel` for every portfolio (not just the active one) since every card renders
/// simultaneously.
struct PortfolioCardModel: Identifiable {
    let id: UUID
    let name: String
    let currentValue: Double
    /// Both nil together when there isn't yet a 24h-old value-history sample for this portfolio
    /// (e.g. created today) — see `PortfolioViewModel.todayChange(for:)`.
    let todayChangeAmount: Double?
    let todayChangePercent: Double?
}

/// The portfolio a long-press actually landed on, captured by value at the moment the press
/// fires (id AND the name shown on that card). Every dialog is driven by this snapshot via
/// `presenting:`, and the destructive action only ever uses the snapshot's id, so the card that
/// was pressed is the card that gets acted on.
private struct PressedPortfolio: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Robinhood-style portfolio switcher: a horizontally-scrollable row of always-visible cards
/// (name, total balance, today's % change), one per portfolio. Also owns the add/rename/delete UI
/// for the up-to-5 portfolio list — small enough to not need a separate management screen.
struct PortfolioPickerHeader: View {
    let portfolios: [Portfolio]
    let activePortfolioId: UUID?
    let cardModel: (Portfolio) -> PortfolioCardModel
    let formatCurrency: (Double) -> String
    let onSelect: (UUID) -> Void
    let onAdd: (String) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    /// Commits a drag-and-drop reorder; the argument is the full list of ids in their new order.
    let onReorder: ([UUID]) -> Void

    @State private var showAddSheet = false
    @State private var newPortfolioName = ""
    /// The card whose long-press sheet is open. Everything that sheet offers - rename, reorder,
    /// delete - happens inside it, so this is the only presentation the long press starts.
    @State private var pressedPortfolio: PressedPortfolio?
    /// The card currently under a finger. Drives the home-screen-style press feedback, so a long
    /// press looks like it is being registered instead of nothing happening for four tenths of a
    /// second and then a sheet appearing.
    @State private var pressingCardId: UUID?

    private var canAddMore: Bool { portfolios.count < PortfolioManager.maxPortfolios }

    var body: some View {
        cardsLayer
            .sheet(isPresented: $showAddSheet) {
                portfolioNameSheet(title: "New Portfolio", text: $newPortfolioName, confirmTitle: "Create") {
                    onAdd(newPortfolioName)
                    newPortfolioName = ""
                    showAddSheet = false
                } onCancel: {
                    showAddSheet = false
                }
            }
            // One half-height sheet for the whole long-press menu, matching the broadcast
            // retention sheet. `.sheet(item:)` rather than a boolean: the sheet is built FROM the
            // pressed card's own snapshot, so it can never be handed a different portfolio than
            // the one that was held.
            .sheet(item: $pressedPortfolio) { target in
                PortfolioActionsSheet(
                    target: target,
                    portfolios: portfolios,
                    formatCurrency: formatCurrency,
                    cardModel: cardModel,
                    onRename: onRename,
                    onDelete: onDelete,
                    onReorder: onReorder
                )
                .presentationDetents([.medium, .large])
            }
    }

    // MARK: - State A: expanded cards

    private var cardsLayer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Explicit `id:` + `.id(...)` pins each card's view identity to its portfolio id,
                // so SwiftUI can't reuse one card's context menu (and its captured portfolio) for
                // a neighbouring card when the list reorders or a portfolio is added/removed.
                ForEach(portfolios, id: \.id) { portfolio in
                    card(for: portfolio)
                        .id(portfolio.id)
                }
                if canAddMore {
                    addCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func card(for portfolio: Portfolio) -> some View {
        let model = cardModel(portfolio)

        return PortfolioCardView(
            portfolio: portfolio,
            valueText: formatCurrency(model.currentValue),
            changePercent: model.todayChangePercent,
            isActive: portfolio.id == activePortfolioId,
            isPressing: pressingCardId == portfolio.id,
            // Stays lifted while ITS sheet is open, the way a home-screen icon stays raised under
            // its context menu - the sheet only covers the lower half, so the card it belongs to
            // is still on screen and worth identifying.
            isMenuTarget: pressedPortfolio?.id == portfolio.id,
            onTap: {
                Haptics.impact(.light)
                onSelect(portfolio.id)
            },
            onLongPress: {
                Haptics.impact(.medium)
                // Hand straight over to the lifted state - leaving the shrink on would make the
                // card jump from small to large as the sheet appears.
                pressingCardId = nil
                pressedPortfolio = PressedPortfolio(id: portfolio.id, name: portfolio.name)
            },
            onPressingChanged: { pressing in
                pressingCardId = pressing ? portfolio.id : nil
            }
        )
        // Lets SwiftUI skip the cards whose inputs did not change when one card's press state does.
        .equatable()
    }

    private var addCard: some View {
        Button {
            newPortfolioName = ""
            showAddSheet = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Add")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 80, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundColor(.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    private func portfolioNameSheet(
        title: String,
        text: Binding<String>,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        NavigationStack {
            Form {
                TextField("Portfolio Name", text: text)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: onConfirm)
                        .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(180)])
    }
}

/// Everything a long press on a portfolio card offers, in one half-height sheet.
///
/// Rename, reorder and delete all happen HERE rather than each opening its own presentation. That
/// is partly the requested shape and partly a correctness property: the sheet is built from the
/// pressed card's own snapshot, so every action inside it acts on the portfolio that was held,
/// with nothing in between that could resolve to another one.
private struct PortfolioActionsSheet: View {
    let target: PressedPortfolio
    let portfolios: [Portfolio]
    let formatCurrency: (Double) -> String
    let cardModel: (Portfolio) -> PortfolioCardModel
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onReorder: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode {
        case menu, rename, reorder, confirmDelete
    }

    @State private var mode: Mode = .menu
    @State private var renameText: String
    /// Working copy for the drag. Seeded on appear - re-seeding every render would fight the drag.
    @State private var reorderDraft: [Portfolio] = []

    init(
        target: PressedPortfolio,
        portfolios: [Portfolio],
        formatCurrency: @escaping (Double) -> String,
        cardModel: @escaping (Portfolio) -> PortfolioCardModel,
        onRename: @escaping (UUID, String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onReorder: @escaping ([UUID]) -> Void
    ) {
        self.target = target
        self.portfolios = portfolios
        self.formatCurrency = formatCurrency
        self.cardModel = cardModel
        self.onRename = onRename
        self.onDelete = onDelete
        self.onReorder = onReorder
        _renameText = State(initialValue: target.name)
    }

    /// The last portfolio can't be deleted - every wallet keeps at least one - and there is
    /// nothing to reorder with only one card.
    private var hasOtherPortfolios: Bool { portfolios.count > 1 }

    private var trimmedRename: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
    }

    private var title: String {
        switch mode {
        case .menu: return target.name
        case .rename: return "Rename"
        case .reorder: return "Reorder"
        case .confirmDelete: return "Delete Portfolio"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .menu: menuList
        case .rename: renameForm
        case .reorder: reorderList
        case .confirmDelete: deleteConfirmation
        }
    }

    // MARK: - Modes

    private var menuList: some View {
        Form {
            Section {
                Button {
                    renameText = target.name
                    mode = .rename
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if hasOtherPortfolios {
                    Button {
                        reorderDraft = portfolios
                        mode = .reorder
                    } label: {
                        Label("Reorder Portfolios", systemImage: "arrow.up.arrow.down")
                    }
                    Button(role: .destructive) {
                        mode = .confirmDelete
                    } label: {
                        Label("Delete '\(target.name)'", systemImage: "trash")
                    }
                }
            } footer: {
                if !hasOtherPortfolios {
                    Text("This is your only portfolio, so it can't be deleted or reordered.")
                }
            }
        }
        .tint(.accentColor)
    }

    private var renameForm: some View {
        Form {
            Section {
                TextField("Portfolio Name", text: $renameText)
            } footer: {
                Text("Only the name changes. Transactions stay where they are.")
            }
        }
    }

    private var reorderList: some View {
        List {
            Section {
                ForEach(reorderDraft, id: \.id) { portfolio in
                    HStack(spacing: 12) {
                        Text(portfolio.name)
                            .font(.body.weight(portfolio.id == target.id ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(formatCurrency(cardModel(portfolio).currentValue))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .onMove { indices, destination in
                    reorderDraft.move(fromOffsets: indices, toOffset: destination)
                    Haptics.impact(.light)
                }
            } footer: {
                Text("Drag a portfolio to change the order its card appears in.")
            }
        }
        // Always-on edit mode: this mode exists only to reorder, so making the user tap Edit
        // first would be a step with no other purpose.
        .environment(\.editMode, .constant(.active))
    }

    private var deleteConfirmation: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    // Last line of defence: only delete if that exact id is still in the list.
                    guard portfolios.contains(where: { $0.id == target.id }) else {
                        dismiss()
                        return
                    }
                    onDelete(target.id)
                    dismiss()
                } label: {
                    Label("Delete '\(target.name)'", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text("'\(target.name)' and its transactions will be deleted. This can't be undone.")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // From a sub-mode this steps back to the menu rather than closing outright, so a
            // mis-tap costs one tap instead of the whole long press.
            Button(mode == .menu ? "Cancel" : "Back") {
                if mode == .menu { dismiss() } else { mode = .menu }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            switch mode {
            case .rename:
                Button("Save") {
                    onRename(target.id, trimmedRename)
                    dismiss()
                }
                .disabled(trimmedRename.isEmpty)
            case .reorder:
                Button("Done") {
                    onReorder(reorderDraft.map(\.id))
                    dismiss()
                }
            case .menu, .confirmDelete:
                EmptyView()
            }
        }
    }
}

/// One portfolio card, as its own `Equatable` view.
///
/// Equatable so that pressing one card does not rebuild the others: the press state lives on the
/// header, so any change to it re-evaluates the header's body and with it every card, even though
/// only one card's inputs actually changed.
private struct PortfolioCardView: View, Equatable {
    let portfolio: Portfolio
    let valueText: String
    let changePercent: Double?
    let isActive: Bool
    let isPressing: Bool
    let isMenuTarget: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onPressingChanged: (Bool) -> Void

    /// The closures are excluded deliberately: they are rebuilt every time the header renders and
    /// would never compare equal, which would defeat the comparison entirely. They only ever read
    /// the header's `@State`, whose storage is stable across renders.
    static func == (lhs: PortfolioCardView, rhs: PortfolioCardView) -> Bool {
        lhs.portfolio == rhs.portfolio
            && lhs.valueText == rhs.valueText
            && lhs.changePercent == rhs.changePercent
            && lhs.isActive == rhs.isActive
            && lhs.isPressing == rhs.isPressing
            && lhs.isMenuTarget == rhs.isMenuTarget
    }

    /// How long the card must be held before its sheet opens.
    ///
    /// Shorter than the 0.5s system default and than the 0.4s this started at, which felt like a
    /// wait. It stays comfortably above a deliberate tap, and the gesture's own 10pt movement
    /// tolerance is what keeps a scroll of the card row from ever reaching it.
    private static let longPressDuration: TimeInterval = 0.25

    private var isPositive: Bool { (changePercent ?? 0) >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(portfolio.name)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
            Text(valueText)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let changePercent {
                HStack(spacing: 2) {
                    Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                    Text("\(String(format: "%.2f", abs(changePercent)))%")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundColor(isPositive ? .green : .red)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 140, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isMenuTarget || isActive ? Color.accentColor : Color.white.opacity(0.15),
                            lineWidth: isMenuTarget ? 2 : (isActive ? 1.5 : 0.8)
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Shrinks under the finger and lifts once its sheet is open. Springs rather than linear
        // fades, so the card settles the way a pressed icon does.
        .scaleEffect(isPressing ? 0.94 : (isMenuTarget ? 1.04 : 1))
        .brightness(isPressing ? -0.04 : 0)
        // Applied only when there is a shadow to draw. A shadow forces an offscreen pass, and
        // leaving a transparent one installed on every card pays for it on all of them.
        .modifier(LiftShadow(active: isMenuTarget))
        .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isPressing)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isMenuTarget)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(
            minimumDuration: Self.longPressDuration,
            perform: onLongPress,
            onPressingChanged: onPressingChanged
        )
    }
}

/// Adds the lifted shadow only when it is actually visible.
private struct LiftShadow: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
        } else {
            content
        }
    }
}
