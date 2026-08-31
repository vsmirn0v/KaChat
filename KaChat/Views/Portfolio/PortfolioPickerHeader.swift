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
    /// it is committed on release and discarded otherwise. Stored as the portfolios themselves
    /// rather than ids: this is read several times per card per frame while dragging, and
    /// rebuilding it from ids meant constructing a dictionary on every one of those reads.
    @State private var liveOrder: [Portfolio]?

    /// Card contents captured when a drag starts, and used for every frame of it.
    ///
    /// `cardModel` is NOT cheap - per card it filters the whole transaction list twice and
    /// recomputes a seven-day value history - and `formatCurrency` allocates two NumberFormatters
    /// on top. Dragging updates state on every touch move, which re-rendered every card, so all of
    /// that ran for all five cards at display rate. Nothing it produces can change during a drag,
    /// so it is computed once at the start instead.
    @State private var frozenCards: [UUID: FrozenCard] = [:]

    fileprivate struct FrozenCard {
        let model: PortfolioCardModel
        let valueText: String
    }

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
        guard let liveOrder, liveOrder.count == portfolios.count else { return portfolios }
        return liveOrder
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
        let order = orderedPortfolios
        guard let index = order.firstIndex(where: { $0.id == portfolio.id }) else { return }
        // Freeze what every card renders before the first frame of the drag - see `frozenCards`.
        var frozen: [UUID: FrozenCard] = [:]
        for item in order {
            let model = cardModel(item)
            frozen[item.id] = FrozenCard(model: model, valueText: formatCurrency(model.currentValue))
        }
        frozenCards = frozen
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
              let currentIndex = order.firstIndex(where: { $0.id == portfolio.id }) else { return }
        let slots = Int((dragTranslation / Self.cardStride).rounded())
        let target = min(max(dragStartIndex + slots, 0), order.count - 1)
        guard target != currentIndex else { return }
        let moved = order.remove(at: currentIndex)
        order.insert(moved, at: target)
        // Animated HERE rather than by an `.animation(value:)` on every card - that modifier had
        // to build and compare an id array per card per frame just to notice this same change.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            liveOrder = order
        }
        Haptics.impact(.light)
    }

    private func commitDrag() {
        if let liveOrder {
            let ids = liveOrder.map(\.id)
            if ids != portfolios.map(\.id) {
                onReorder(ids)
                Haptics.success()
            }
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
        frozenCards = [:]
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
        // Frozen while a drag is running, live otherwise - see `frozenCards`.
        let frozen = frozenCards[portfolio.id]
        let model = frozen?.model ?? cardModel(portfolio)
        let isDragging = draggingCardId == portfolio.id

        return PortfolioCardView(
            portfolio: portfolio,
            valueText: frozen?.valueText ?? formatCurrency(model.currentValue),
            changePercent: model.todayChangePercent,
            isActive: portfolio.id == activePortfolioId,
            isPressing: pressingCardId == portfolio.id,
            isDragging: isDragging,
            // Stays lifted while ITS sheet is open, the way a home-screen icon stays raised under
            // its context menu - the sheet only covers the lower half, so the card it belongs to
            // is still on screen and worth identifying.
            isMenuTarget: pressedPortfolio?.id == portfolio.id,
            dragOffset: isDragging ? dragCarryOffset(for: portfolio) : 0,
            flattenBackground: draggingCardId != nil,
            onTap: {
                Haptics.impact(.light)
                onSelect(portfolio.id)
            },
            onPressBegan: {
                if pressingCardId != portfolio.id {
                    pressingCardId = portfolio.id
                    Haptics.impact(.medium)
                }
            },
            onDragChanged: { translation in
                if draggingCardId == nil {
                    guard abs(translation) > Self.dragActivationDistance,
                          portfolios.count > 1 else { return }
                    beginDrag(of: portfolio)
                }
                dragTranslation = translation
                updateDragTarget(for: portfolio)
            },
            onDragEnded: {
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
        // Without this every card is rebuilt on every touch move of a drag. Only the dragged
        // card's inputs actually change, so the other four compare equal and are skipped.
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
/// Equatable matters here: a drag writes state on every touch move, which re-evaluates the
/// header's body and with it all five cards. Only the dragged card's inputs actually change, so
/// the rest compare equal and SwiftUI skips them entirely. The closures are excluded from `==`
/// deliberately - they are rebuilt every time the header renders and would never compare equal,
/// which would defeat the whole point. They only ever read the header's `@State` (stable storage)
/// and the portfolio list, which cannot change mid-drag.
private struct PortfolioCardView: View, Equatable {
    let portfolio: Portfolio
    let valueText: String
    let changePercent: Double?
    let isActive: Bool
    let isPressing: Bool
    let isDragging: Bool
    let isMenuTarget: Bool
    let dragOffset: CGFloat
    /// True while ANY card is being dragged. See `cardBackground`.
    let flattenBackground: Bool
    let onTap: () -> Void
    let onPressBegan: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    static func == (lhs: PortfolioCardView, rhs: PortfolioCardView) -> Bool {
        lhs.portfolio == rhs.portfolio
            && lhs.valueText == rhs.valueText
            && lhs.changePercent == rhs.changePercent
            && lhs.isActive == rhs.isActive
            && lhs.isPressing == rhs.isPressing
            && lhs.isDragging == rhs.isDragging
            && lhs.isMenuTarget == rhs.isMenuTarget
            && lhs.dragOffset == rhs.dragOffset
            && lhs.flattenBackground == rhs.flattenBackground
    }

    private var isPositive: Bool { (changePercent ?? 0) >= 0 }
    private var isLifted: Bool { isMenuTarget || isDragging }

    /// `.regularMaterial` is a live backdrop blur: it re-samples and re-blurs whatever is behind
    /// it every time the view moves. Five of them being transformed at display rate is the
    /// expensive part of a drag, and the blur is invisible anyway while everything is sliding, so
    /// a drag swaps all the cards to an opaque fill for its duration.
    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let border = shape.stroke(
            isMenuTarget || isActive ? Color.accentColor : Color.white.opacity(0.15),
            lineWidth: isMenuTarget ? 2 : (isActive ? 1.5 : 0.8)
        )
        if flattenBackground {
            shape.fill(Color(uiColor: .secondarySystemBackground)).overlay(border)
        } else {
            shape.fill(.regularMaterial).overlay(border)
        }
    }

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
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Shrinks under the finger and lifts once picked up or once its sheet is open. Springs
        // rather than linear fades, so the card settles the way a pressed icon does.
        .scaleEffect(isDragging ? 1.06 : (isPressing ? 0.94 : (isMenuTarget ? 1.04 : 1)))
        .brightness(isPressing && !isDragging ? -0.04 : 0)
        .offset(x: dragOffset)
        // Applied only when there is a shadow to draw. A shadow forces an offscreen pass, and
        // leaving a transparent one installed on every card pays for it on all of them.
        .modifier(LiftShadow(active: isLifted))
        .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isPressing)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isMenuTarget)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isDragging)
        .onTapGesture(perform: onTap)
        // Hold, then EITHER move to reorder OR let go to open the menu - the same choice a
        // home-screen icon offers. A long press is required first, so an immediate swipe still
        // belongs to the enclosing scroll view rather than picking a card up by accident.
        .gesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        onPressBegan()
                    case .second(true, let drag):
                        guard let drag else { return }
                        onDragChanged(drag.translation.width)
                    default:
                        break
                    }
                }
                .onEnded { _ in onDragEnded() }
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
