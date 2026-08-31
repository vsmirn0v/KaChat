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

/// The Kaspa Hub tab: a grid of everything that isn't in the dock, and the section you picked.
///
/// The type and `AppTab.ecosystem` keep their original names because that case's raw value is
/// persisted in saved dock arrangements - see the note on the enum case.
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
            } else {
                grid
            }
        }
        // Deliberately NOT animated, and no transition on either branch.
        //
        // A cross-fade here fades the whole subtree, navigation bar included - so the balance in
        // the bar dimmed out of white and back on every move between sections, which read as it
        // flickering and resettling rather than as the page changing. Each section brings its own
        // navigation bar (that is what makes it look identical whether it is reached from here or
        // from its own dock tab), so switching does rebuild the bar; without the fade that swap is
        // instant and the balance simply stays put.
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
                // ProfileAppsView sets its own title; only the shared header items are added.
                ProfileAppsView()
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
            .navigationTitle(AppTab.ecosystem.label)
            // Stated rather than left to the default, because it has to MATCH every section: all
            // four use a large title, and a grid that resolved to inline would give the bar a
            // different height, moving the balance the moment you opened anything.
            .navigationBarTitleDisplayMode(.large)
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
            // A square whose size comes from the column, with the content laid OVER it.
            //
            // The tile used to size itself - full column width, a fixed 104pt height - which was
            // neither square nor guaranteed uniform: a longer name is a taller label, and anything
            // that made the content exceed the fixed height would have grown that one tile alone.
            // As an overlay the label cannot influence the size at all, so every tile is the same
            // square whatever it is called.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
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
            Text("KaPosts, Broadcasts, ChangeNOW Swap and Kaspa Websites appear here when they are not in your dock. Manage them in Settings > Customization > Customize Dock.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
    }
}
