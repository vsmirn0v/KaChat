import SwiftUI

/// Which Ecosystem section is open, shared so a notification tap can open one from outside.
///
/// The dock tab itself is the way back out - re-tapping it calls `closeSection` (see
/// `MainTabView.handleTabSelectionChange`), so the same button that got you in gets you out and
/// there is no second back affordance competing with each section's own navigation bar.
@MainActor
final class EcosystemRouter: ObservableObject {
    static let shared = EcosystemRouter()

    @Published private(set) var openSectionTab: AppTab?

    private init() {}

    func openSection(_ tab: AppTab) {
        guard AppTab.ecosystemCandidates.contains(tab) else { return }
        openSectionTab = tab
    }

    func closeSection() {
        guard openSectionTab != nil else { return }
        openSectionTab = nil
    }
}

/// The Ecosystem tab: a grid of everything that isn't in the dock, and the section you picked.
///
/// Membership is computed, not configured - `AppTab.ecosystemSections` drops anything the user has
/// hidden and anything that already has its own dock slot, so a feature is never in both places at
/// once. Move Swap into the dock and it leaves this grid; hide it and it disappears from both.
struct EcosystemView: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var router = EcosystemRouter.shared

    /// Three across, as requested. Fixed count rather than adaptive so the tiles line up the same
    /// way whatever the section count is.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    private var sections: [AppTab] {
        AppTab.ecosystemSections(from: settingsViewModel.settings)
    }

    var body: some View {
        Group {
            if let open = router.openSectionTab, sections.contains(open) {
                // The section owns the whole screen, with its own navigation bar - the way it
                // looks when it has its own dock tab. Nothing is wrapped around it.
                sectionContent(open)
                    .transition(.opacity)
            } else {
                grid
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: router.openSectionTab)
        // A section the user has since moved into the dock (or hidden) must not stay open here,
        // or it would be on screen twice.
        .onChange(of: sections) { current in
            if let open = router.openSectionTab, !current.contains(open) {
                router.closeSection()
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ tab: AppTab) -> some View {
        switch tab {
        case .kaposts:
            KaPostsPageView()
        case .broadcasts:
            NavigationStack { BroadcastListView() }
        case .swap:
            SwapView()
        case .apps:
            NavigationStack {
                ProfileAppsView()
                    .navigationTitle(AppTab.apps.ecosystemTitle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            ConnectionStatusIndicator()
                        }
                        ToolbarItem(placement: .principal) {
                            BalanceToolbarLabel()
                        }
                    }
            }
        default:
            EmptyView()
        }
    }

    private var grid: some View {
        NavigationStack {
            ScrollView {
                if sections.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(sections) { tab in
                            tile(tab)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Ecosystem")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
        }
    }

    private func tile(_ tab: AppTab) -> some View {
        Button {
            Haptics.impact(.light)
            router.openSection(tab)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 30)
                Text(tab.ecosystemTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Reached by putting every section into the dock, or hiding them all - in both cases the
    /// features are still there, just not here, so this says where they went.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Nothing here right now")
                .font(.headline)
            Text("KaPosts, Broadcasts, Swap and the websites list appear here when they are not in your dock. Manage them in Settings > Customization > Customize Dock.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
    }
}
