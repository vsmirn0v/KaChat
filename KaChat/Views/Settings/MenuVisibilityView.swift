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
                    icon: "dot.radiowaves.left.and.right",
                    label: "Broadcasts",
                    isOn: Binding(
                        get: { !settingsViewModel.settings.hideBroadcasts },
                        set: { settingsViewModel.settings.hideBroadcasts = !$0; settingsViewModel.saveSettings() }
                    ),
                    locked: false
                )
            } header: {
                Text("Choose which tabs appear in your bottom menu.")
            } footer: {
                Text("Press and drag a tab in the preview below to reorder it.")
            }
        }
        .navigationTitle("Menu")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            tabOrderPreview
        }
    }

    private func menuRow(icon: String, label: String, isOn: Binding<Bool>, locked: Bool) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundColor(.primary)
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
