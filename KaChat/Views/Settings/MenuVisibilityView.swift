import SwiftUI
import UniformTypeIdentifiers
import Foundation

/// Settings > Customization > Customize Dock — which bottom tabs show up, and in what order. Chats/Profile
/// are permanently on (Settings itself is reached from Profile now, not its own tab); everything
/// else can each be hidden, all defaulting to shown for a new install (4.0). A
/// live preview of the real tab bar is pinned to the bottom of this screen specifically (it isn't
/// visible otherwise, since Settings now opens as a sheet over the real TabView) - press-and-drag
/// a pill in the preview to reorder it, matching Android's own "reorder by dragging the bar
/// itself" behavior instead of a separate up/down control.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var draggingTab: AppTab?

    private var visibleTabs: [AppTab] {
        AppTab.visible(from: settingsViewModel.settings)
    }

    /// KaPosts is on but the dock is full, so it opens via re-tapping the Chats tab - surfaced as
    /// a hint on its row so the behavior is discoverable right where it was toggled on.
    private var kaPostsReTapHint: String? {
        let settings = settingsViewModel.settings
        guard !settings.hideKaPostsTab else { return nil }
        return AppTab.kaPostsAccessibleViaChatsTab(from: settings)
            ? "Dock is full - open it by tapping the Chats tab again" : nil
    }

    /// Same discoverability hint for Broadcasts when it's masked behind the Chats-tab cycle.
    private var broadcastsReTapHint: String? {
        let settings = settingsViewModel.settings
        guard !settings.hideBroadcasts else { return nil }
        return AppTab.broadcastsAccessibleViaChatsTab(from: settings)
            ? "Dock is full - open it by tapping the Chats tab again" : nil
    }

    /// Apps doesn't ride the Chats-tab cycle - it's a regular dock tab that needs a free slot.
    /// Enabled but not visible means the dock is full: tell the user to free a slot. While it
    /// actually sits in the dock, note that it moved off the Profile screen instead.
    private var appsHint: String? {
        let settings = settingsViewModel.settings
        guard !settings.hideAppsTab else { return nil }
        return AppTab.visible(from: settings).contains(.apps)
            ? "Moved out of Profile while on the dock"
            : "Dock is full - turn another tab off to show Apps"
    }

    var body: some View {
        List {
            Section {
                // Always-shown (locked) rows first, then everything toggleable - matching
                // Android's MenuVisibilityScreen ordering.
                menuRow(icon: AppTab.chats.icon, label: AppTab.chats.label, isOn: .constant(true), locked: true)
                menuRow(icon: AppTab.profile.icon, label: AppTab.profile.label, isOn: .constant(true), locked: true)
                menuRow(
                    icon: AppTab.portfolio.icon,
                    label: AppTab.portfolio.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hidePortfolioTab },
                        set: { settingsViewModel.settings.hidePortfolioTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false
                )
                menuRow(
                    icon: AppTab.coldStorage.icon,
                    label: AppTab.coldStorage.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideColdStorageTab },
                        set: { settingsViewModel.settings.hideColdStorageTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false
                )
                menuRow(
                    icon: AppTab.swap.icon,
                    label: AppTab.swap.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideSwapTab },
                        set: { settingsViewModel.settings.hideSwapTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false
                )
                menuRow(
                    icon: AppTab.kaposts.icon,
                    label: AppTab.kaposts.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideKaPostsTab },
                        set: { settingsViewModel.settings.hideKaPostsTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    hint: kaPostsReTapHint
                )
                menuRow(
                    icon: AppTab.apps.icon,
                    label: AppTab.apps.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideAppsTab },
                        set: { settingsViewModel.settings.hideAppsTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    hint: appsHint
                )
                menuRow(
                    icon: AppTab.broadcasts.icon,
                    label: AppTab.broadcasts.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideBroadcasts },
                        set: { settingsViewModel.settings.hideBroadcasts = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    hint: broadcastsReTapHint
                )
            } header: {
                Text("Choose which tabs appear in your dock.")
            } footer: {
                Text("Press and drag a tab in the preview below to reorder it. The dock shows up to \(AppTab.maxDockItems) items - if it's full, KaPosts and Broadcasts stay available by tapping the Chats tab to cycle through them; other tabs need a free slot to appear.")
            }
        }
        .navigationTitle("Customize Dock")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            tabOrderPreview
        }
    }

    private func menuRow(icon: String, label: String, isOn: Binding<Bool>, locked: Bool, hint: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(label, systemImage: icon)
                    .foregroundColor(.primary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if locked {
                Text("Always shown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(.accentColor)
            }
        }
    }

    // MARK: - Live reorderable preview

    private var tabOrderPreview: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(visibleTabs) { tab in
                    tabPreviewPill(tab)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
        }
        .animation(.default, value: visibleTabs)
    }

    private func tabPreviewPill(_ tab: AppTab) -> some View {
        VStack(spacing: 4) {
            Image(systemName: tab.icon)
                .font(.system(size: 20))
            Text(tab.label)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(.accentColor)
        .frame(maxWidth: .infinity)
        .opacity(draggingTab == tab ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onDrag {
            draggingTab = tab
            return NSItemProvider(object: tab.rawValue as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: TabOrderDropDelegate(
                tab: tab,
                draggingTab: $draggingTab,
                settingsViewModel: settingsViewModel
            )
        )
    }
}

/// Reorders `settings.tabOrder` live as the dragged pill passes over a neighbor - the standard
/// "swap on hover, commit on drop" SwiftUI drag-reorder pattern.
private struct TabOrderDropDelegate: DropDelegate {
    let tab: AppTab
    @Binding var draggingTab: AppTab?
    let settingsViewModel: SettingsViewModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTab = nil
        // Persisted once here, not on every `dropEntered` hover - saveSettings() does a full
        // JSON encode + UserDefaults write + settingsDidChange broadcast, which was firing many
        // times per second while the pill dragged across neighbors, visibly stuttering the drag.
        settingsViewModel.saveSettings()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingTab, draggingTab != tab else { return }

        var order = AppTab.resolvedOrder(from: settingsViewModel.settings)
        guard let fromIndex = order.firstIndex(of: draggingTab),
              let toIndex = order.firstIndex(of: tab) else { return }

        if fromIndex != toIndex {
            order.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            settingsViewModel.settings.tabOrder = order.map { $0.rawValue }
        }
    }
}
