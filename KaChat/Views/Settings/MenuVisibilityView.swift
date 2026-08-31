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

    /// Child Mode removes Swaps, KaPosts and Broadcasts from the whole app - their toggles
    /// disappear from this screen too so they can't even be flipped "for later" while it's on.
    private var childModeOn: Bool {
        settingsViewModel.settings.childModeEnabled
    }

    /// Where a feature currently lives, shown on its own row.
    ///
    /// The three states worth saying out loud: it has a dock slot, it does not fit and so sits in
    /// Ecosystem, or Ecosystem itself is off and it has nowhere to go. The last one is the only
    /// way to lose access to an enabled feature, so it is the one that most needs saying.
    private func placementHint(for tab: AppTab, hidden: Bool) -> String? {
        let settings = settingsViewModel.settings
        guard !hidden else { return nil }
        if AppTab.visible(from: settings).contains(tab) { return "In your dock" }
        if AppTab.ecosystemSections(from: settings).contains(tab) { return "In Ecosystem" }
        return "Dock is full and Ecosystem is off - turn one on to reach it"
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
                    icon: AppTab.ecosystem.icon,
                    label: AppTab.ecosystem.label,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideEcosystemTab },
                        set: { settingsViewModel.settings.hideEcosystemTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    hint: settingsViewModel.settings.hideEcosystemTab
                        ? nil
                        : "Holds whatever is turned on below but not in your dock"
                )
                if !childModeOn {
                    menuRow(
                        icon: AppTab.swap.icon,
                        label: AppTab.swap.ecosystemTitle,
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
                        hint: placementHint(for: .kaposts, hidden: settingsViewModel.settings.hideKaPostsTab)
                    )
                }
                menuRow(
                    icon: AppTab.apps.icon,
                    label: AppTab.apps.ecosystemTitle,
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideAppsTab },
                        set: { settingsViewModel.settings.hideAppsTab = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false,
                    hint: placementHint(for: .apps, hidden: settingsViewModel.settings.hideAppsTab)
                )
                if !childModeOn {
                    menuRow(
                        icon: AppTab.broadcasts.icon,
                        label: AppTab.broadcasts.label,
                        isOn: Binding(
                            get: { !settingsViewModel.settings.hideBroadcasts },
                            set: { settingsViewModel.settings.hideBroadcasts = !$0; settingsViewModel.saveSettings() }
                        ),
                        locked: false,
                        hint: placementHint(for: .broadcasts, hidden: settingsViewModel.settings.hideBroadcasts)
                    )
                }
            } header: {
                Text("Choose which tabs appear in your dock.")
            } footer: {
                if childModeOn {
                    Text("Press and drag a tab in the preview below to reorder it. The dock shows up to \(AppTab.maxDockItems) items. Swap, KaPosts and Broadcasts are unavailable while Child Mode is on (Settings > Security > Child Mode).")
                } else {
                    Text("Press and drag a tab in the preview below to reorder it. The dock shows up to \(AppTab.maxDockItems) items - if it's full, KaPosts and Broadcasts stay available by tapping the Chats tab to cycle through them; other tabs need a free slot to appear.")
                }
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
