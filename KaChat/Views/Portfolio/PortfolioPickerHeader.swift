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
    @State private var renamingPortfolio: Portfolio?
    @State private var renameText = ""
    /// The card whose long-press menu is open.
    @State private var pressedPortfolio: PressedPortfolio?
    /// The card the user chose Delete for, held separately so the confirmation is its own step.
    @State private var pendingDeletion: PressedPortfolio?
    @State private var showReorderSheet = false

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
        // The long-press menu. This is a plain confirmationDialog rather than `.contextMenu`
        // because the whole card row lives inside ONE row of the Portfolio screen's List: a
        // context menu attached to each card there is claimed by the row's own menu interaction,
        // which resolves to the first card whichever card you actually pressed. That is what made
        // Delete always remove the first portfolio no matter which one was held.
        .confirmationDialog(
            Text(pressedPortfolio?.name ?? "Portfolio"),
            isPresented: Binding(
                get: { pressedPortfolio != nil },
                set: { if !$0 { pressedPortfolio = nil } }
            ),
            titleVisibility: .visible,
            presenting: pressedPortfolio
        ) { target in
            Button("Rename") {
                pressedPortfolio = nil
                guard let portfolio = portfolios.first(where: { $0.id == target.id }) else { return }
                renameText = portfolio.name
                renamingPortfolio = portfolio
            }
            if portfolios.count > 1 {
                Button("Reorder Portfolios") {
                    pressedPortfolio = nil
                    showReorderSheet = true
                }
                Button("Delete '\(target.name)'", role: .destructive) {
                    pressedPortfolio = nil
                    pendingDeletion = target
                }
            }
            Button("Cancel", role: .cancel) { pressedPortfolio = nil }
        }
        .sheet(isPresented: $showReorderSheet) {
            PortfolioReorderSheet(
                portfolios: portfolios,
                formatCurrency: formatCurrency,
                cardModel: cardModel,
                onDone: { ordered in
                    onReorder(ordered)
                    showReorderSheet = false
                },
                onCancel: { showReorderSheet = false }
            )
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

/// Drag-and-drop reordering for the portfolio cards.
///
/// A sheet with a standard editable List, not dragging the cards in place: the cards live in a
/// horizontally-scrolling row inside the Portfolio screen's List, so a horizontal drag-to-reorder
/// gesture would be competing with two scroll views for the same finger. A List in edit mode gets
/// the native drag handles, the usual lift-and-slide animation, and VoiceOver's move actions for
/// free, and it cannot fight a scroll.
///
/// The order is committed only on Done, so a drag that turns out wrong is undone by Cancel rather
/// than by dragging everything back.
private struct PortfolioReorderSheet: View {
    let portfolios: [Portfolio]
    let formatCurrency: (Double) -> String
    let cardModel: (Portfolio) -> PortfolioCardModel
    let onDone: ([UUID]) -> Void
    let onCancel: () -> Void

    /// Working copy. Seeded once on appear - re-seeding on every render would fight the drag.
    @State private var draft: [Portfolio] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft, id: \.id) { portfolio in
                        HStack(spacing: 12) {
                            Text(portfolio.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatCurrency(cardModel(portfolio).currentValue))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onMove { indices, destination in
                        draft.move(fromOffsets: indices, toOffset: destination)
                        Haptics.impact(.light)
                    }
                } footer: {
                    Text("Drag a portfolio to change the order its card appears in.")
                }
            }
            // Always-on edit mode: the sheet exists only to reorder, so making the user tap Edit
            // first would be a step with no other purpose.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Portfolios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(draft.map(\.id)) }
                }
            }
        }
        .onAppear {
            if draft.isEmpty { draft = portfolios }
        }
    }
}
