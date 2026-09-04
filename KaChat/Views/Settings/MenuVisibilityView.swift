import SwiftUI

/// Settings > Customization > Customize Dock - where each tab lives, arranged on a picture of the
/// thing being arranged.
///
/// The screen used to be two `List` sections with "Move to Hub" buttons and edit-mode grips. It
/// worked, but it asked you to hold a layout in your head: the dock is a row of five at the bottom
/// of the screen and the Hub is a three-across grid, and neither looked anything like a table row.
/// So this is the Hub grid up top and the dock bar along the bottom, both drawn the way they
/// actually appear - including their widths, which is why neither draws placeholders for the
/// slots it is not using.
///
/// Two gestures, one job each. A TAP moves a tab between the two: tap something in the Hub and it
/// joins the dock, tap something in the dock and it goes back to the Hub. A HOLD lifts a tab and
/// dragging it slides the tabs it passes over into the space it left, so the arrangement under
/// your finger is the arrangement you will get.
///
/// Placement, not visibility. Every tab is either in the dock or in the Hub, and always in exactly
/// one of them, so nothing can end up nowhere. Kaspa Hub and Profile are pinned to the dock
/// (`AppTab.isPinnedToDock`) - the Hub because it is what holds everything not in the dock, and
/// Profile because it is the way to Settings and your accounts. They reorder like the rest; what
/// they cannot do is leave.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    /// Set when a tap cannot be honoured, so the reason appears where the tap happened instead of
    /// the tap looking like it did nothing.
    @State private var refusal: String?

    /// The arrangement being edited, which is NOT the live one until this screen is left.
    ///
    /// This screen is pushed from Settings, which lives inside the Profile tab. Writing the real
    /// `dockTabs` on every move changes `AppTab.visible(from:)`, which is the collection
    /// `MainTabView`'s TabView builds its pages from - so every single move tore down and rebuilt
    /// the tab pages underneath this screen, including the navigation stack this screen is sitting
    /// in. That threw the user out of the screen and could leave a tab rendering black, which is
    /// the same failure `MainTabView` already guards against for tabs that disappear entirely.
    ///
    /// Under a drag-only design it took a deliberate gesture to hit that. Now a single tap moves a
    /// tab, so it happened on every tap. The bottom of this screen is already an accurate picture
    /// of the dock, so nothing is lost by leaving the real one alone until the user is done.
    @State private var draftDock: [AppTab] = []
    @State private var draftHub: [AppTab] = []
    /// Guards against persisting before the drafts have been seeded, which would save two empty
    /// lists over a real arrangement.
    @State private var loaded = false

    // MARK: Drag state
    //
    // Hand-rolled rather than `.draggable`/`.dropDestination`. A system drag can tell you what was
    // dropped where, but not where the drag is hovering right now - and the whole point of this
    // gesture is that the other tabs move aside while you are still holding one.

    /// The tab being held, and where it started in its own section.
    @State private var draggingTab: AppTab?
    @State private var dragOrigin = 0
    @State private var dragInDock = false
    /// Live finger translation, so the held tab tracks the finger exactly.
    @State private var dragTranslation: CGSize = .zero
    /// The index the held tab would land on if released now. Everything between here and
    /// `dragOrigin` slides one place to fill the gap.
    @State private var dropTarget = 0

    /// Measured, because a slot's width is the bar divided by however many tabs are in it - the
    /// same arithmetic the drag uses to decide which slot the finger is over.
    @State private var dockWidth: CGFloat = 0
    @State private var hubWidth: CGFloat = 0

    private var settings: AppSettings { settingsViewModel.settings }
    // Falling back to the live arrangement until the drafts are seeded, so the first frame draws
    // the real dock rather than an empty one.
    private var dockTabs: [AppTab] { loaded ? draftDock : AppTab.visible(from: settings) }
    private var hubTabs: [AppTab] { loaded ? draftHub : AppTab.ecosystemSections(from: settings) }
    private var dockIsFull: Bool { dockTabs.count >= AppTab.maxDockItems }

    /// Three across, matching `EcosystemView`'s grid - the point of this screen is that it looks
    /// like the real thing.
    private static let hubColumnCount = 3
    private static let hubSpacing: CGFloat = 14
    private let hubColumns = Array(
        repeating: GridItem(.flexible(), spacing: hubSpacing),
        count: hubColumnCount
    )

    private var dockSlotWidth: CGFloat {
        dockTabs.isEmpty ? 0 : dockWidth / CGFloat(dockTabs.count)
    }

    /// One grid step: a tile plus the gap after it. Tiles are square, so this is both the
    /// horizontal and the vertical stride.
    private var hubStride: CGFloat {
        let columns = CGFloat(Self.hubColumnCount)
        let tile = (hubWidth - Self.hubSpacing * (columns - 1)) / columns
        return tile + Self.hubSpacing
    }

    private var slideAnimation: Animation { .spring(response: 0.28, dampingFraction: 0.82) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    AppTab.ecosystem.label,
                    detail: "Opened from the \(AppTab.ecosystem.label) tab, in this order. Nothing here is switched off - it is one tap further away than the dock. Tap one to move it into your dock, or hold and drag to reorder."
                )

                if hubTabs.isEmpty {
                    emptyHubHint
                } else {
                    hubGrid
                }

                if let refusal {
                    Label(refusal, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .coordinateSpace(name: "dockEditor")
        .navigationTitle("Customize Dock")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dockPreview
        }
        .onAppear {
            guard !loaded else { return }
            draftDock = AppTab.visible(from: settings)
            draftHub = AppTab.ecosystemSections(from: settings)
            loaded = true
        }
        .onDisappear { persist() }
        // Backgrounding is the one way off this screen that never calls onDisappear, and an app
        // killed from the background would otherwise lose the arrangement.
        .onChange(of: scenePhase) { phase in
            if phase != .active { persist() }
        }
    }

    // MARK: - Header

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Hub

    private var hubGrid: some View {
        LazyVGrid(columns: hubColumns, spacing: Self.hubSpacing) {
            ForEach(Array(hubTabs.enumerated()), id: \.element) { index, tab in
                let held = draggingTab == tab && !dragInDock
                hubTile(tab)
                    .offset(hubOffset(for: index))
                    .scaleEffect(held ? 1.06 : 1)
                    .shadow(color: .black.opacity(held ? 0.28 : 0), radius: held ? 10 : 0, y: held ? 4 : 0)
                    .zIndex(held ? 1 : 0)
                    // The held tile must track the finger exactly, so only the tiles moving ASIDE
                    // are animated.
                    .animation(held ? nil : slideAnimation, value: dropTarget)
                    .animation(held ? nil : slideAnimation, value: draggingTab)
                    .gesture(holdAndDrag(tab: tab, index: index, inDock: false))
            }
        }
        .background(widthReader { hubWidth = $0 })
    }

    /// Same square-over-a-clear-canvas construction as `EcosystemView.tile`, so a tile here is the
    /// size and shape it will be there whatever it is called.
    private func hubTile(_ tab: AppTab) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                VStack(spacing: 10) {
                    tabIcon(tab, size: 26)
                        .frame(height: 30)
                    Text(tab.ecosystemTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { moveToDock(tab) }
    }

    /// With everything in the dock there is nothing to tap or drag up here, so this is a sentence
    /// rather than a target: the way back is to tap something in the dock.
    private var emptyHubHint: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundColor(.secondary.opacity(0.5))
            .frame(height: 96)
            .overlay {
                Text("Everything is in your dock.\nTap a dock item to move it back here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
    }

    // MARK: - Dock

    /// The dock as it is drawn for real: a row of icon-over-label items on a bar at the bottom of
    /// the screen. Pinned to the bottom via `safeAreaInset` for the same reason.
    private var dockPreview: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Your Dock")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(dockTabs.count) of \(AppTab.maxDockItems)")
                    .font(.caption)
                    .foregroundColor(dockIsFull ? .orange : .secondary)
            }
            .padding(.horizontal, 16)

            // No placeholder slots for the unused capacity. The real dock divides its whole width
            // between however many tabs it has, so a four-tab dock is four WIDER items and not
            // four items with a gap on the right - and a preview that showed the gap would be
            // showing an arrangement the user is never going to see. The count above the bar is
            // what says how much room is left.
            HStack(spacing: 0) {
                ForEach(Array(dockTabs.enumerated()), id: \.element) { index, tab in
                    let held = draggingTab == tab && dragInDock
                    dockItem(tab)
                        .offset(x: dockOffset(for: index))
                        .scaleEffect(held ? 1.12 : 1)
                        .shadow(color: .black.opacity(held ? 0.3 : 0), radius: held ? 8 : 0, y: held ? 3 : 0)
                        .zIndex(held ? 1 : 0)
                        .animation(held ? nil : slideAnimation, value: dropTarget)
                        .animation(held ? nil : slideAnimation, value: draggingTab)
                        .gesture(holdAndDrag(tab: tab, index: index, inDock: true))
                }
            }
            .background(widthReader { dockWidth = $0 })
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            Text(dockIsFull
                 ? "Your dock is full. Tap one of these to move it up to \(AppTab.ecosystem.label) and free a slot. \(AppTab.ecosystem.label) and \(AppTab.profile.label) must stay in the dock."
                 : "Tap a dock item to move it up to \(AppTab.ecosystem.label), or hold and drag to reorder. \(AppTab.ecosystem.label) and \(AppTab.profile.label) must stay in the dock.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func dockItem(_ tab: AppTab) -> some View {
        VStack(spacing: 4) {
            tabIcon(tab, size: 22)
                .frame(height: 24)
            Text(tab.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // Pinned tabs are dimmed rather than hidden: they hold their real dock position, and the
        // dimming is what says "this one is not yours to move OUT" before you tap it. Dragging
        // them to a different slot is still fine.
        .opacity(tab.isPinnedToDock ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { moveToHub(tab) }
    }

    @ViewBuilder
    private func tabIcon(_ tab: AppTab, size: CGFloat) -> some View {
        if tab.usesKaspaLogo {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tab.icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Reports its container's width without taking part in the layout.
    private func widthReader(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size.width) }
                .onChange(of: proxy.size.width) { report($0) }
        }
    }

    // MARK: - Dragging

    /// A hold, then a drag. Sequenced rather than simultaneous so an ordinary swipe still scrolls
    /// the page: until the press has been held, this gesture has not claimed the touch.
    private func holdAndDrag(tab: AppTab, index: Int, inDock: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("dockEditor")))
            .onChanged { value in
                switch value {
                case .first:
                    beginDrag(tab: tab, index: index, inDock: inDock)
                case .second(_, let drag):
                    // The hold can be reported straight through to the drag phase, so the pick-up
                    // is done here too rather than only in `.first`.
                    if draggingTab != tab { beginDrag(tab: tab, index: index, inDock: inDock) }
                    guard let drag else { return }
                    dragTranslation = drag.translation
                    dropTarget = targetIndex(for: drag.translation, inDock: inDock)
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(tab: AppTab, index: Int, inDock: Bool) {
        guard draggingTab != tab else { return }
        Haptics.impact(.medium)
        draggingTab = tab
        dragOrigin = index
        dragInDock = inDock
        dragTranslation = .zero
        dropTarget = index
    }

    /// Which slot the finger is over, as whole slots travelled from where the drag began. Derived
    /// from the FIXED origin rather than from the last target, so it depends only on where the
    /// finger is - which is what stops a fast drag oscillating between two slots.
    private func targetIndex(for translation: CGSize, inDock: Bool) -> Int {
        let count = inDock ? dockTabs.count : hubTabs.count
        guard count > 0 else { return 0 }
        if inDock {
            guard dockSlotWidth > 0 else { return dragOrigin }
            let slots = Int((translation.width / dockSlotWidth).rounded())
            return min(max(dragOrigin + slots, 0), count - 1)
        } else {
            guard hubStride > 0 else { return dragOrigin }
            let columns = Int((translation.width / hubStride).rounded())
            let rows = Int((translation.height / hubStride).rounded())
            return min(max(dragOrigin + columns + rows * Self.hubColumnCount, 0), count - 1)
        }
    }

    /// Where a tab sits while a drag is in progress: the held one follows the finger, and every
    /// tab between the gap it left and the slot it is hovering over shifts one place to close it.
    private func displacedIndex(_ index: Int) -> Int {
        if dropTarget > dragOrigin, index > dragOrigin, index <= dropTarget { return index - 1 }
        if dropTarget < dragOrigin, index >= dropTarget, index < dragOrigin { return index + 1 }
        return index
    }

    private func dockOffset(for index: Int) -> CGFloat {
        guard draggingTab != nil, dragInDock else { return 0 }
        if index == dragOrigin { return dragTranslation.width }
        return CGFloat(displacedIndex(index) - index) * dockSlotWidth
    }

    private func hubOffset(for index: Int) -> CGSize {
        guard draggingTab != nil, !dragInDock else { return .zero }
        if index == dragOrigin { return dragTranslation }
        let moved = displacedIndex(index)
        let columns = Self.hubColumnCount
        return CGSize(
            width: CGFloat(moved % columns - index % columns) * hubStride,
            height: CGFloat(moved / columns - index / columns) * hubStride
        )
    }

    /// Commits the hovered arrangement.
    ///
    /// Without animation, deliberately: the tabs are already drawn where the new order puts them,
    /// so animating the order change would move everything a second time from where it already is.
    private func endDrag() {
        defer {
            draggingTab = nil
            dragTranslation = .zero
        }
        guard let tab = draggingTab, dropTarget != dragOrigin else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if dragInDock {
                var dock = dockTabs
                dock.remove(at: dragOrigin)
                dock.insert(tab, at: min(dropTarget, dock.count))
                commit(dock: dock, hub: hubTabs, animated: false)
            } else {
                var hub = hubTabs
                hub.remove(at: dragOrigin)
                hub.insert(tab, at: min(dropTarget, hub.count))
                commit(dock: dockTabs, hub: hub, animated: false)
            }
        }
    }

    // MARK: - Moves

    /// Tap in the Hub: join the dock, at the end, where the space you can see already is.
    private func moveToDock(_ tab: AppTab) {
        guard !dockIsFull else {
            refuse("Your dock is full. Tap something in the dock to move it up here first.")
            return
        }
        commit(dock: dockTabs.filter { $0 != tab } + [tab], hub: hubTabs.filter { $0 != tab })
    }

    /// Tap in the dock: back to the Hub, at the end of the grid.
    private func moveToHub(_ tab: AppTab) {
        guard !tab.isPinnedToDock else {
            refuse("\(tab.label) has to stay in your dock.")
            return
        }
        commit(dock: dockTabs.filter { $0 != tab }, hub: hubTabs.filter { $0 != tab } + [tab])
    }

    private func refuse(_ message: String) {
        Haptics.error()
        withAnimation { refusal = message }
    }

    /// Both lists are written together, so a tab can never be missing from both or present in
    /// both after a move.
    private func commit(dock: [AppTab], hub: [AppTab], animated: Bool = true) {
        Haptics.impact(.light)
        let apply = {
            refusal = nil
            draftDock = dock
            draftHub = hub
        }
        if animated {
            withAnimation(.snappy(duration: 0.22)) { apply() }
        } else {
            apply()
        }
    }

    /// Writes the draft to the real settings, and so rebuilds the tab bar - once, on the way out.
    private func persist() {
        guard loaded else { return }
        let dock = draftDock.map(\.rawValue)
        let hub = draftHub.map(\.rawValue)
        guard dock != settings.dockTabs || hub != settings.hubTabs else { return }
        settingsViewModel.settings.dockTabs = dock
        settingsViewModel.settings.hubTabs = hub
        settingsViewModel.saveSettings()
    }
}
