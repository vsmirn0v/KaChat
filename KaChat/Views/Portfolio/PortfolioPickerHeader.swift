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

/// The portfolio a long-press actually landed on, captured by value at the moment the Delete
/// menu item is tapped (id AND the name shown on that card). The confirmation dialog is driven
/// by this snapshot via `presenting:` and the destructive action only ever uses the snapshot's
/// id, so the row that was pressed is the row that gets deleted - nothing re-reads shared view
/// state after the press, which is what let the old code act on a stale portfolio.
private struct PendingPortfolioDeletion: Identifiable, Equatable {
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

    @State private var showAddSheet = false
    @State private var newPortfolioName = ""
    @State private var renamingPortfolio: Portfolio?
    @State private var renameText = ""
    @State private var pendingDeletion: PendingPortfolioDeletion?

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
        .sheet(item: $renamingPortfolio) { portfolio in
            portfolioNameSheet(title: "Rename Portfolio", text: $renameText, confirmTitle: "Save") {
                onRename(portfolio.id, renameText)
                renamingPortfolio = nil
            } onCancel: {
                renamingPortfolio = nil
            }
            // Same guard as the delete path: seed the field from the item SwiftUI actually
            // presented, not from a separate @State written just before presentation.
            .onAppear { renameText = portfolio.name }
        }
        // `presenting:` hands the pressed card's own snapshot to the title, the buttons and the
        // message, so every part of the confirmation is built from the same value the long-press
        // captured. Nothing here reads `pendingDeletion` again at fire time.
        .confirmationDialog(
            Text("Delete Portfolio"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { target in
            // The destructive button itself names the portfolio, so a mis-targeted delete is
            // visible before it happens rather than only in the dialog title.
            Button("Delete '\(target.name)'", role: .destructive) {
                // Last line of defence: only delete if that exact id is still in the list.
                guard portfolios.contains(where: { $0.id == target.id }) else {
                    pendingDeletion = nil
                    return
                }
                onDelete(target.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { target in
            Text("'\(target.name)' and its transactions will be deleted. This can't be undone.")
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
        .contextMenu {
            Button {
                renameText = portfolio.name
                renamingPortfolio = portfolio
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if portfolios.count > 1 {
                Button(role: .destructive) {
                    // Snapshot the pressed card's id and name right here; everything downstream
                    // uses this value, never a lookup that could resolve to another card.
                    pendingDeletion = PendingPortfolioDeletion(id: portfolio.id, name: portfolio.name)
                } label: {
                    Label("Delete '\(portfolio.name)'", systemImage: "trash")
                }
            }
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
