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
        let isActive = portfolio.id == activePortfolioId
        let isPositive = (model.todayChangeAmount ?? 0) >= 0

        return VStack(alignment: .leading, spacing: 6) {
            Text(model.name)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
            Text(formatCurrency(model.currentValue))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let percent = model.todayChangePercent {
                HStack(spacing: 2) {
                    Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                    Text("\(String(format: "%.2f", abs(percent)))%")
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
                        .stroke(isActive ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isActive ? 1.5 : 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            Haptics.impact(.light)
            onSelect(portfolio.id)
        }
        // Snapshot the pressed card's id and name right here; everything downstream uses this
        // value, never a lookup that could resolve to another card.
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.impact(.medium)
            pressedPortfolio = PressedPortfolio(id: portfolio.id, name: portfolio.name)
        }
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
