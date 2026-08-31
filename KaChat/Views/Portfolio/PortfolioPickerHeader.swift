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
    /// The card being dragged to a new position, once a held card has actually moved.
    @State private var draggingCardId: UUID?
    /// Where the drag started in the CURRENT order, so the target index is computed from a fixed
    /// baseline instead of from a position that keeps changing underneath it.
    @State private var dragStartIndex: Int?
    @State private var dragTranslation: CGFloat = 0
    /// The order being previewed mid-drag. nil means "no drag in progress, use `portfolios`";
    /// it is committed on release and discarded otherwise.
    @State private var liveOrder: [UUID]?

    /// Card width plus the HStack's spacing - one full slot. Cards are a fixed width, which is
    /// what makes a drag position resolvable by arithmetic instead of by measuring every card.
    private static let cardWidth: CGFloat = 140
    private static let cardSpacing: CGFloat = 12
    private static let cardStride: CGFloat = cardWidth + cardSpacing
    /// How far a held card must move before it counts as a reorder rather than a menu open.
    private static let dragActivationDistance: CGFloat = 12

    private var canAddMore: Bool { portfolios.count < PortfolioManager.maxPortfolios }

    /// The cards as they should currently render: the live drag preview when one is in progress,
    /// otherwise whatever the manager holds.
    private var orderedPortfolios: [Portfolio] {
        guard let liveOrder else { return portfolios }
        let byId = Dictionary(uniqueKeysWithValues: portfolios.map { ($0.id, $0) })
        let reordered = liveOrder.compactMap { byId[$0] }
        // A portfolio added or deleted mid-drag would leave the preview short; fall back rather
        // than render a list that is missing a card.
        return reordered.count == portfolios.count ? reordered : portfolios
    }

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

    // MARK: - Drag reordering

    /// How far the dragged card must be pushed to stay under the finger.
    ///
    /// Its slot moves as the preview reorders, so the raw translation would leave the card
    /// drifting a full slot away every time it swapped with a neighbour. Subtracting the distance
    /// its slot has already travelled cancels that out.
    private func dragCarryOffset(for portfolio: Portfolio) -> CGFloat {
        guard let dragStartIndex,
              let currentIndex = orderedPortfolios.firstIndex(where: { $0.id == portfolio.id })
        else { return dragTranslation }
        return dragTranslation - CGFloat(currentIndex - dragStartIndex) * Self.cardStride
    }

    private func beginDrag(of portfolio: Portfolio) {
        let order = orderedPortfolios.map(\.id)
        guard let index = order.firstIndex(of: portfolio.id) else { return }
        liveOrder = order
        dragStartIndex = index
        draggingCardId = portfolio.id
        Haptics.impact(.light)
    }

    /// Moves the dragged card to whichever slot the finger is currently over.
    ///
    /// Computed from the FIXED start index plus whole slots travelled, so the result depends only
    /// on where the finger is - not on the order of intermediate updates, which is what makes a
    /// fast drag land somewhere sensible instead of oscillating.
    private func updateDragTarget(for portfolio: Portfolio) {
        guard let dragStartIndex, var order = liveOrder,
              let currentIndex = order.firstIndex(of: portfolio.id) else { return }
        let slots = Int((dragTranslation / Self.cardStride).rounded())
        let target = min(max(dragStartIndex + slots, 0), order.count - 1)
        guard target != currentIndex else { return }
        order.remove(at: currentIndex)
        order.insert(portfolio.id, at: target)
        liveOrder = order
        Haptics.impact(.light)
    }

    private func commitDrag() {
        if let liveOrder, liveOrder != portfolios.map(\.id) {
            onReorder(liveOrder)
            Haptics.success()
        }
        clearDragState()
    }

    private func cancelDrag() {
        clearDragState()
    }

    private func clearDragState() {
        draggingCardId = nil
        dragStartIndex = nil
        dragTranslation = 0
        // Held until the parent publishes the committed order, so the cards do not flash back to
        // the old positions for a frame in between.
        DispatchQueue.main.async { liveOrder = nil }
    }

    // MARK: - State A: expanded cards

    private var cardsLayer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Explicit `id:` + `.id(...)` pins each card's view identity to its portfolio id,
                // so SwiftUI can't reuse one card's context menu (and its captured portfolio) for
                // a neighbouring card when the list reorders or a portfolio is added/removed.
                ForEach(orderedPortfolios, id: \.id) { portfolio in
                    card(for: portfolio)
                        .id(portfolio.id)
                        // The dragged card rides above its neighbours as they shuffle under it.
                        .zIndex(draggingCardId == portfolio.id ? 1 : 0)
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
        let isPressing = pressingCardId == portfolio.id
        let isDragging = draggingCardId == portfolio.id
        // Stays lifted while ITS sheet is open, the way a home-screen icon stays raised under its
        // context menu - the sheet only covers the lower half, so the card it belongs to is still
        // on screen and worth identifying.
        let isMenuTarget = pressedPortfolio?.id == portfolio.id

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
                        .stroke(
                            isMenuTarget || isActive ? Color.accentColor : Color.white.opacity(0.15),
                            lineWidth: isMenuTarget ? 2 : (isActive ? 1.5 : 0.8)
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Shrinks under the finger and lifts once the sheet is up. Springs rather than linear
        // fades, so the card settles the way a pressed icon does.
        .scaleEffect(isDragging ? 1.06 : (isPressing ? 0.94 : (isMenuTarget ? 1.04 : 1)))
        .brightness(isPressing && !isDragging ? -0.04 : 0)
        .offset(x: isDragging ? dragCarryOffset(for: portfolio) : 0)
        .shadow(
            color: Color.black.opacity(isMenuTarget || isDragging ? 0.35 : 0),
            radius: isMenuTarget || isDragging ? 14 : 0,
            x: 0,
            y: isMenuTarget || isDragging ? 6 : 0
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isPressing)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isMenuTarget)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isDragging)
        // The neighbours slide as the drag reorders them; the dragged card itself is positioned
        // by the offset above, so it must not animate its own slot change.
        .animation(isDragging ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: orderedPortfolios.map(\.id))
        .onTapGesture {
            Haptics.impact(.light)
            onSelect(portfolio.id)
        }
        // Snapshot the pressed card's id and name right here; everything downstream uses this
        // value, never a lookup that could resolve to another card.
        // Hold, then EITHER move to reorder OR let go to open the menu - the same choice a
        // home-screen icon offers. A long press is required first, so an immediate swipe still
        // belongs to the enclosing scroll view rather than picking a card up by accident.
        .gesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        // Held long enough, not yet moved.
                        if pressingCardId != portfolio.id {
                            pressingCardId = portfolio.id
                            Haptics.impact(.medium)
                        }
                    case .second(true, let drag):
                        guard let drag else { return }
                        if draggingCardId == nil {
                            guard abs(drag.translation.width) > Self.dragActivationDistance,
                                  portfolios.count > 1 else { return }
                            beginDrag(of: portfolio)
                        }
                        dragTranslation = drag.translation.width
                        updateDragTarget(for: portfolio)
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    if draggingCardId != nil {
                        commitDrag()
                    } else if pressingCardId == portfolio.id {
                        // Held and released without moving: the menu.
                        pressingCardId = nil
                        pressedPortfolio = PressedPortfolio(id: portfolio.id, name: portfolio.name)
                    }
                    pressingCardId = nil
                }
        )
        // Covers the press being cancelled by the enclosing scroll view, which ends the sequence
        // without ever reaching `onEnded`.
        .onDisappear { if draggingCardId == portfolio.id { cancelDrag() } }
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
