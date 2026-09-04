import SwiftUI
import UniformTypeIdentifiers

/// Settings > Customization > Customize Dock - where each tab lives, arranged on a picture of the
/// thing being arranged.
///
/// The screen used to be two `List` sections with "Move to Hub" buttons and edit-mode grips. It
/// worked, but it asked you to hold a layout in your head: the dock is a row of five at the bottom
/// of the screen and the Hub is a three-across grid, and neither looked anything like a table row.
/// So this is the Hub grid up top and the dock bar along the bottom, both drawn the way they
/// actually appear, and you drag things between them.
///
/// Placement, not visibility. Every tab is either in the dock or in the Hub, and always in exactly
/// one of them, so nothing can end up nowhere. Kaspa Hub and Profile are pinned to the dock
/// (`AppTab.isPinnedToDock`) - the Hub because it is what holds everything not in the dock, and
/// Profile because it is the way to Settings and your accounts.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// The tab currently being dragged, so its source slot can dim and the drop targets can tell
    /// a real drag from a stray provider.
    @State private var draggingTab: AppTab?

    private var settings: AppSettings { settingsViewModel.settings }
    private var dockTabs: [AppTab] { AppTab.visible(from: settings) }
    private var hubTabs: [AppTab] { AppTab.ecosystemSections(from: settings) }
    private var dockIsFull: Bool { dockTabs.count >= AppTab.maxDockItems }

    /// Three across, matching `EcosystemView`'s grid - the point of this screen is that it looks
    /// like the real thing.
    private let hubColumns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    AppTab.ecosystem.label,
                    detail: "Opened from the \(AppTab.ecosystem.label) tab, in this order. Nothing here is switched off - it is one tap further away than the dock."
                )

                if hubTabs.isEmpty {
                    emptyHubDropZone
                } else {
                    LazyVGrid(columns: hubColumns, spacing: 14) {
                        ForEach(hubTabs) { tab in
                            hubTile(tab)
                                .draggable(tab)
                                .dropDestination(for: AppTab.self) { items, _ in
                                    guard let dragged = items.first else { return false }
                                    return insertIntoHub(dragged, before: tab)
                                }
                        }
                    }
                    // Dropping on the gaps between tiles still means "put it in the Hub", it just
                    // has no position to insert at - so it lands at the end.
                    .dropDestination(for: AppTab.self) { items, _ in
                        guard let dragged = items.first else { return false }
                        return appendToHub(dragged)
                    }
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
            .opacity(draggingTab == tab ? 0.35 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A Hub with nothing in it still has to be a drop target, or the last tab moved out of it
    /// could never be moved back.
    private var emptyHubDropZone: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundColor(.secondary.opacity(0.5))
            .frame(height: 96)
            .overlay {
                Text("Everything is in your dock.\nDrag something here to move it out.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .dropDestination(for: AppTab.self) { items, _ in
                guard let dragged = items.first else { return false }
                return appendToHub(dragged)
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
                            return insertIntoDock(dragged, before: tab)
                        }
                }
                // An unfilled dock keeps its empty slots visible, so there is somewhere obvious
                // to aim at and the count is legible without reading the number.
                ForEach(dockTabs.count..<AppTab.maxDockItems, id: \.self) { _ in
                    emptyDockSlot
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .dropDestination(for: AppTab.self) { items, _ in
                guard let dragged = items.first else { return false }
                return appendToDock(dragged)
            }

            Text(dockIsFull
                 ? "The dock is full. Drag something up to \(AppTab.ecosystem.label) to free a slot."
                 : "Drag tiles down here to put them in your dock.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
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
        .opacity(draggingTab == tab ? 0.35 : 1)
        .contentShape(Rectangle())
        // Pinned tabs render but do not lift: the Hub holds whatever is not in the dock, and
        // Profile is the way to Settings, so neither can be moved out of it.
        .ifDraggable(!tab.isPinnedToDock, tab: tab)
    }

    private var emptyDockSlot: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundColor(.secondary.opacity(0.35))
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .dropDestination(for: AppTab.self) { items, _ in
                guard let dragged = items.first else { return false }
                return appendToDock(dragged)
            }
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

    /// All four moves funnel through here so a tab can never be in both lists or neither: the
    /// destination list is rebuilt from a copy with the tab removed from BOTH first.
    private func place(_ tab: AppTab, intoDockAt dockIndex: Int?, intoHubAt hubIndex: Int?) -> Bool {
        var dock = dockTabs
        var hub = hubTabs

        if dockIndex != nil {
            // Pinned tabs are already in the dock; a reorder is fine, an eviction is not.
            guard dock.contains(tab) || !dockIsFull else { return false }
        } else if tab.isPinnedToDock {
            return false
        }

        dock.removeAll { $0 == tab }
        hub.removeAll { $0 == tab }

        if let index = dockIndex {
            dock.insert(tab, at: min(max(index, 0), dock.count))
        } else if let index = hubIndex {
            hub.insert(tab, at: min(max(index, 0), hub.count))
        }

        commit(dock: dock, hub: hub)
        return true
    }

    private func insertIntoDock(_ tab: AppTab, before target: AppTab) -> Bool {
        guard tab != target else { return false }
        var dock = dockTabs
        dock.removeAll { $0 == tab }
        let index = dock.firstIndex(of: target) ?? dock.count
        return place(tab, intoDockAt: index, intoHubAt: nil)
    }

    private func appendToDock(_ tab: AppTab) -> Bool {
        guard !dockTabs.contains(tab) else { return false }
        return place(tab, intoDockAt: dockTabs.count, intoHubAt: nil)
    }

    private func insertIntoHub(_ tab: AppTab, before target: AppTab) -> Bool {
        guard tab != target else { return false }
        var hub = hubTabs
        hub.removeAll { $0 == tab }
        let index = hub.firstIndex(of: target) ?? hub.count
        return place(tab, intoDockAt: nil, intoHubAt: index)
    }

    private func appendToHub(_ tab: AppTab) -> Bool {
        guard !hubTabs.contains(tab) else { return false }
        return place(tab, intoDockAt: nil, intoHubAt: hubTabs.count)
    }

    /// Both lists are written together, so a tab can never be missing from both or present in
    /// both after a move.
    private func commit(dock: [AppTab], hub: [AppTab]) {
        Haptics.impact(.light)
        settingsViewModel.settings.dockTabs = dock.map(\.rawValue)
        settingsViewModel.settings.hubTabs = hub.map(\.rawValue)
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

private extension View {
    /// `.draggable` applied conditionally without an `if` in the view tree - a structural branch
    /// here would give the pinned and unpinned cases different identities and re-create the item
    /// whenever one changed.
    @ViewBuilder
    func ifDraggable(_ enabled: Bool, tab: AppTab) -> some View {
        if enabled {
            self.draggable(tab)
        } else {
            self
        }
    }
}
