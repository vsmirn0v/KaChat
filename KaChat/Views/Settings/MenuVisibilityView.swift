import SwiftUI
import Foundation

/// Settings > Customization > Customize Dock - where each tab lives.
///
/// Placement, not visibility. Every tab is either in the dock or in Kaspa Hub, and it is always in
/// exactly one of them, so nothing can end up nowhere. That was possible before: tabs were toggled
/// on or off and the dock then took the first five of an order, silently dropping the rest - which
/// is how Profile could vanish from the dock with nothing on screen explaining it.
///
/// Kaspa Hub itself is pinned to the dock (`AppTab.isPinnedToDock`), because it is what holds
/// whatever is not in the dock. Everything else, Chats and Profile included, is movable.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Always on: this screen exists to rearrange, so making the user find an Edit button first
    /// would be a step with no other purpose.
    @State private var editMode: EditMode = .active

    private var settings: AppSettings { settingsViewModel.settings }

    private var dockTabs: [AppTab] { AppTab.visible(from: settings) }

    private var hubTabs: [AppTab] { AppTab.ecosystemSections(from: settings) }

    private var dockIsFull: Bool { dockTabs.count >= AppTab.maxDockItems }

    var body: some View {
        List {
            Section {
                ForEach(dockTabs) { tab in
                    row(tab, inDock: true)
                }
                .onMove(perform: moveWithinDock)
            } header: {
                HStack {
                    Text("In Your Dock")
                    Spacer()
                    Text("\(dockTabs.count) of \(AppTab.maxDockItems)")
                        .font(.caption)
                        .foregroundColor(dockIsFull ? .orange : .secondary)
                }
            } footer: {
                if dockIsFull {
                    Text("The dock is full. Move something to \(AppTab.ecosystem.label) to free a slot. Drag to reorder.")
                } else {
                    Text("Drag to reorder. \(AppTab.ecosystem.label) always stays here - it is what holds everything below.")
                }
            }

            Section {
                if hubTabs.isEmpty {
                    Text("Everything is in your dock.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(hubTabs) { tab in
                        row(tab, inDock: false)
                    }
                    .onMove(perform: moveWithinHub)
                }
            } header: {
                Text("In \(AppTab.ecosystem.label)")
            } footer: {
                Text("Opened from the \(AppTab.ecosystem.label) tab, in this order. Nothing here is switched off - it is one tap further away than the dock. Drag to reorder.")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Customize Dock")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ tab: AppTab, inDock: Bool) -> some View {
        HStack {
            Label(tab.ecosystemTitle, systemImage: tab.icon)
                .foregroundColor(.primary)
            Spacer()
            if tab.isPinnedToDock {
                Text("Always in dock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    move(tab, toDock: !inDock)
                } label: {
                    // Names where it would GO, so it reads as the action it performs rather than
                    // as a label for where the row already is.
                    Text(inDock ? "Move to \(AppTab.ecosystem.label)" : "Move to Dock")
                        .font(.caption.weight(.semibold))
                }
                // Borderless so the tap lands on the button rather than the whole row, which is
                // also a drag handle here.
                .buttonStyle(.borderless)
                .disabled(!inDock && dockIsFull)
                .foregroundColor(!inDock && dockIsFull ? .secondary : .accentColor)
            }
        }
    }

    private func move(_ tab: AppTab, toDock: Bool) {
        guard !tab.isPinnedToDock else { return }
        var dock = dockTabs
        var hub = hubTabs
        if toDock {
            guard dock.count < AppTab.maxDockItems, !dock.contains(tab) else { return }
            hub.removeAll { $0 == tab }
            dock.append(tab)
        } else {
            dock.removeAll { $0 == tab }
            if !hub.contains(tab) { hub.append(tab) }
        }
        // Appended, then draggable into place - both lists are reorderable, so landing at the end
        // is a starting position rather than a final one.
        commit(dock: dock, hub: hub)
    }

    private func moveWithinDock(from source: IndexSet, to destination: Int) {
        var dock = dockTabs
        dock.move(fromOffsets: source, toOffset: destination)
        commit(dock: dock, hub: hubTabs)
    }

    private func moveWithinHub(from source: IndexSet, to destination: Int) {
        var hub = hubTabs
        hub.move(fromOffsets: source, toOffset: destination)
        commit(dock: dockTabs, hub: hub)
    }

    /// Both lists are written together, so a tab can never be missing from both or present in
    /// both after a move.
    private func commit(dock: [AppTab], hub: [AppTab]) {
        settingsViewModel.settings.dockTabs = dock.map(\.rawValue)
        settingsViewModel.settings.hubTabs = hub.map(\.rawValue)
        settingsViewModel.saveSettings()
    }
}
