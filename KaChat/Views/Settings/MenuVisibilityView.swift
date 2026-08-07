import SwiftUI
import UniformTypeIdentifiers
import Foundation

/// Settings > Customization > Menu — which bottom tabs show up, and in what order. Chats/Profile
/// are permanently on (Settings itself is reached from Profile now, not its own tab);
/// Portfolio/Cold Storage/Swap can each be hidden, all defaulting to shown for a new install. A
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

    /// Dock menus currently toggled ON among Portfolio, Storage, Swap and More. Chats/Profile
    /// are always-on and don't count; KaPosts and Broadcasts are EXEMPT - when the dock is full
    /// they ride the Chats slot (re-tapping the Chats tab cycles through them) instead of taking
    /// a dock place, so they never need to push anything out.
    private var enabledDockToggleCount: Int {
        let settings = settingsViewModel.settings
        return [
            !settings.hidePortfolioTab,
            !settings.hideColdStorageTab,
            !settings.hideSwapTab,
            !settings.hideAppsTab,
            !settings.hideMoreItem
        ].filter { $0 }.count
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

    /// At most 3 optional dock menus may be ON at once (2 locked + 3 optional = the 5-item dock).
    private var atMenuLimit: Bool { enabledDockToggleCount >= 3 }

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
                    locked: false,
                    limitLocked: atMenuLimit && settingsViewModel.settings.hidePortfolioTab
                )
                menuRow(
                    icon: AppTab.coldStorage.icon,
                    label: AppTab.coldStorage.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideColdStorageTab },
                        set: { settingsViewModel.settings.hideColdStorageTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    limitLocked: atMenuLimit && settingsViewModel.settings.hideColdStorageTab
                )
                menuRow(
                    icon: AppTab.swap.icon,
                    label: AppTab.swap.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideSwapTab },
                        set: { settingsViewModel.settings.hideSwapTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    limitLocked: atMenuLimit && settingsViewModel.settings.hideSwapTab
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
                    limitLocked: atMenuLimit && settingsViewModel.settings.hideAppsTab,
                    hint: settingsViewModel.settings.hideAppsTab ? nil : "Moved out of Profile while on the dock"
                )
                menuRow(
                    icon: AppTab.more.icon,
                    label: "\(AppTab.more.label) (+)",
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideMoreItem },
                        set: { settingsViewModel.settings.hideMoreItem = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    limitLocked: atMenuLimit && settingsViewModel.settings.hideMoreItem
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
                Text("Choose which tabs appear in your bottom menu.")
            } footer: {
                Text("Press and drag a tab in the preview below to reorder it. The dock shows up to \(AppTab.maxDockItems) items - if it's full, KaPosts and Broadcasts stay available by tapping the Chats tab to cycle through them. \"More (+)\" opens this screen straight from the dock.")
            }
        }
        .navigationTitle("Menu")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            tabOrderPreview
        }
    }

    private func menuRow(icon: String, label: String, isOn: Binding<Bool>, locked: Bool, limitLocked: Bool = false, hint: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(label, systemImage: icon)
                    .foregroundColor(.primary)
                if limitLocked {
                    Text("Turn another menu off to enable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if let hint {
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
                    .disabled(limitLocked)
            }
        }
        .opacity(limitLocked ? 0.45 : 1)
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
