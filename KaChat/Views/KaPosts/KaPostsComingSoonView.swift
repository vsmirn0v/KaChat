import SwiftUI
import UIKit

/// Landing page for KaPosts - the on-chain social feed arriving in a later 4.0 update. This is
/// deliberately a pure "coming soon" placeholder: no K/K-indexer wiring yet (those live outside
/// the repo as reference material only), so shipping it carries zero protocol surface.
/// NOTE: deliberately has NO NavigationStack of its own. When shown in the Chats slot (full-dock
/// re-tap mode) it overlays ChatListView, which already hosts a NavigationStack - mounting a
/// second one in the same tab slot crashes UIKit with "Layout requested for visible navigation
/// bar ... attempt to nest wrapped navigation controllers". The standalone dock-tab case wraps it
/// at the call site (MainTabView.tabContent) instead.
struct KaPostsComingSoonView: View {
    var body: some View {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "square.and.pencil")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(28)
                    .background(glassBackground(cornerRadius: 32))

                VStack(spacing: 10) {
                    Text("KaPosts")
                        .font(.largeTitle.weight(.bold))
                    Text("Coming Soon")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("A social feed built on Kaspa. Post, follow, and discover - fully on-chain, right inside KaChat.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}
