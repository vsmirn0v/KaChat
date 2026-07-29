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
    @State private var deletingPortfolio: Portfolio?

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
        }
        .confirmationDialog(
            "Delete '\(deletingPortfolio?.name ?? "")' and its transactions? This can't be undone.",
            isPresented: Binding(
                get: { deletingPortfolio != nil },
                set: { if !$0 { deletingPortfolio = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingPortfolio?.id {
                    onDelete(id)
                }
                deletingPortfolio = nil
            }
            Button("Cancel", role: .cancel) { deletingPortfolio = nil }
        }
    }

    // MARK: - State A: expanded cards

    private var cardsLayer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(portfolios) { portfolio in
                    card(for: portfolio)
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
                    deletingPortfolio = portfolio
                } label: {
                    Label("Delete", systemImage: "trash")
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
