import UIKit

/// How many unseen things a tab is holding, wherever that tab is drawn.
///
/// One source for the dock and the Kaspa Hub grid. A tab's placement is the user's arrangement,
/// so the same tab has to say the same thing in either place - and when a badge was computed
/// separately at each site, moving a tab between them silently changed whether it had one.
@MainActor
enum AppTabBadge {
    static func unreadCount(for tab: AppTab) -> Int {
        switch tab {
        // The whole notification feed: Profile hosts the bell that lists it.
        case .profile: return GlobalNotificationCenter.shared.unreadCount
        // KaPosts keeps its own count, already filtered by the per-kind switches in Settings.
        case .kaposts: return KaPostsNotificationCenter.shared.unseenCount
        // Public Chats' share of the feed. Deliberately overlaps Profile's total: the bell is the
        // whole feed, and a tab badge is that tab's part of it.
        case .publicChats: return GlobalNotificationCenter.shared.unreadCount(for: .publicChat)
        default: return 0
        }
    }

    /// Capped in the LABEL, not in the stored count: the real number survives a long absence and
    /// only its rendering is abbreviated. Three characters is as wide as a badge goes before it
    /// starts crowding whatever it sits on.
    static func label(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    /// What the dock shows on `tab`: Profile a red dot while the bell holds anything unread (the
    /// bell itself is a dot, so the dock says the same thing), the others their count.
    static func dockLabel(for tab: AppTab) -> String? {
        let count = unreadCount(for: tab)
        guard count > 0 else { return nil }
        return tab == .profile ? dot : label(count)
    }

    /// A badge with no number: UIKit draws a small red dot for an empty badge value.
    static let dot = ""

    /// Puts Profile's dot straight on the tab bar item too. SwiftUI applies a tab's `.badge`
    /// when it renders the TabView, and a bell entry recorded while another tab is showing could
    /// leave the Profile item without its dot until the next render; setting the UIKit item
    /// directly makes it appear the moment the bell has something, from any tab.
    static func syncProfileDot(dockTabs: [AppTab]) {
        guard let index = dockTabs.firstIndex(of: .profile) else { return }
        let value = dockLabel(for: .profile)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                while let controller = queue.popLast() {
                    if let tabs = controller as? UITabBarController, let items = tabs.tabBar.items, index < items.count {
                        if items[index].badgeValue != value {
                            items[index].badgeColor = .systemRed
                            items[index].badgeValue = value
                        }
                        return
                    }
                    queue.append(contentsOf: controller.children)
                }
            }
        }
    }
}
