import SwiftUI
import UniformTypeIdentifiers

/// Settings > Customization > Customize Dock - where each tab lives, arranged on a picture of the
/// thing being arranged.
///
/// The screen used to be two `List` sections with "Move to Hub" buttons and edit-mode grips. It
/// worked, but it asked you to hold a layout in your head: the dock is a row of five at the bottom
/// of the screen and the Hub is a three-across grid, and neither looked anything like a table row.
/// So this is the Hub grid up top and the dock bar along the bottom, both drawn the way they
/// actually appear.
///
/// Two gestures, one job each. A TAP moves a tab between the two: tap something in the Hub and it
/// joins the dock, tap something in the dock and it goes back to the Hub. A DRAG only reorders,
/// within whichever section the tab is already in. Dragging across the screen to a target you
/// cannot see while your finger is over it was the fiddly part; moving is now a tap, and dragging
/// is left to the one thing a tap cannot express, which is position.
///
/// Placement, not visibility. Every tab is either in the dock or in the Hub, and always in exactly
/// one of them, so nothing can end up nowhere. Kaspa Hub and Profile are pinned to the dock
/// (`AppTab.isPinnedToDock`) - the Hub because it is what holds everything not in the dock, and
/// Profile because it is the way to Settings and your accounts.
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

    private var settings: AppSettings { settingsViewModel.settings }
    // Falling back to the live arrangement until the drafts are seeded, so the first frame draws
    // the real dock rather than an empty one.
    private var dockTabs: [AppTab] { loaded ? draftDock : AppTab.visible(from: settings) }
    private var hubTabs: [AppTab] { loaded ? draftHub : AppTab.ecosystemSections(from: settings) }
    private var dockIsFull: Bool { dockTabs.count >= AppTab.maxDockItems }

    /// Three across, matching `EcosystemView`'s grid - the point of this screen is that it looks
    /// like the real thing.
    private let hubColumns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

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
                    LazyVGrid(columns: hubColumns, spacing: 14) {
                        ForEach(hubTabs) { tab in
                            hubTile(tab)
                                .draggable(tab)
                                .dropDestination(for: AppTab.self) { items, _ in
                                    guard let dragged = items.first else { return false }
                                    return reorderHub(dragged, before: tab)
                                }
                        }
                    }
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

    /// With everything in the dock there is nothing to drag or tap, so this is a sentence rather
    /// than a drop target: the way back is to tap something in the dock.
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

            HStack(spacing: 0) {
                ForEach(dockTabs) { tab in
                    dockItem(tab)
                        .dropDestination(for: AppTab.self) { items, _ in
                            guard let dragged = items.first else { return false }
                            return reorderDock(dragged, before: tab)
                        }
                }
                // An unfilled dock keeps its empty slots visible, so the count is legible without
                // reading the number.
                ForEach(dockTabs.count..<AppTab.maxDockItems, id: \.self) { _ in
                    emptyDockSlot
                }
            }
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
        // Pinned tabs drag like the rest: what they cannot do is LEAVE the dock, and reordering
        // never moves anything out of it. Where Kaspa Hub and Profile sit among the five is still
        // the user's, and the dimming plus the refused tap is what says so.
        .draggable(tab)
    }

    private var emptyDockSlot: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundColor(.secondary.opacity(0.35))
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
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

    // MARK: - Moves

    /// Tap in the Hub: join the dock, at the end, where the empty slot you can see already is.
    private func moveToDock(_ tab: AppTab) {
        guard !dockIsFull else {
            refuse("Your dock is full. Tap something in the dock to move it up here first.")
            return
        }
        var dock = dockTabs
        var hub = hubTabs
        dock.removeAll { $0 == tab }
        hub.removeAll { $0 == tab }
        dock.append(tab)
        commit(dock: dock, hub: hub)
    }

    /// Tap in the dock: back to the Hub, at the end of the grid.
    private func moveToHub(_ tab: AppTab) {
        guard !tab.isPinnedToDock else {
            refuse("\(tab.label) has to stay in your dock.")
            return
        }
        var dock = dockTabs
        var hub = hubTabs
        dock.removeAll { $0 == tab }
        hub.removeAll { $0 == tab }
        hub.append(tab)
        commit(dock: dock, hub: hub)
    }

    /// Drags reorder and nothing else, which is enforced here rather than at the drag source:
    /// membership is the check, so a tab dragged out of the dock and dropped on a Hub tile is
    /// simply refused instead of moving by a gesture the screen says is for ordering. That is also
    /// what lets the pinned tabs drag freely - a reorder cannot evict anything by construction.
    private func reorderDock(_ tab: AppTab, before target: AppTab) -> Bool {
        guard tab != target, dockTabs.contains(tab), let targetIndex = dockTabs.firstIndex(of: target) else {
            return false
        }
        var dock = dockTabs
        dock.removeAll { $0 == tab }
        dock.insert(tab, at: min(targetIndex, dock.count))
        commit(dock: dock, hub: hubTabs)
        return true
    }

    private func reorderHub(_ tab: AppTab, before target: AppTab) -> Bool {
        guard tab != target, hubTabs.contains(tab), let targetIndex = hubTabs.firstIndex(of: target) else {
            return false
        }
        var hub = hubTabs
        hub.removeAll { $0 == tab }
        hub.insert(tab, at: min(targetIndex, hub.count))
        commit(dock: dockTabs, hub: hub)
        return true
    }

    private func refuse(_ message: String) {
        Haptics.error()
        withAnimation { refusal = message }
    }

    /// Both lists are written together, so a tab can never be missing from both or present in
    /// both after a move.
    private func commit(dock: [AppTab], hub: [AppTab]) {
        Haptics.impact(.light)
        withAnimation(.snappy(duration: 0.22)) {
            refusal = nil
            draftDock = dock
            draftHub = hub
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

/// Drag payload for Customize Dock. A plain string identifier rather than a file or an image:
/// what is being dragged is "which tab", and the destination looks it up.
///
/// Declared here rather than on the type in Models.swift so the drag-and-drop dependency belongs
/// to the one screen that drags, not to every consumer of AppTab.
extension AppTab: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kaChatAppTab)
    }
}

extension UTType {
    /// App-private type: dragging a tab out of KaChat into another app should do nothing, and a
    /// public type like `.text` would let it land somewhere as a stray word.
    static let kaChatAppTab = UTType(exportedAs: "com.kachat.app.apptab")
}
