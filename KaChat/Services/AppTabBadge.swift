import Foundation

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
        // Broadcasts' share of the feed. Deliberately overlaps Profile's total: the bell is the
        // whole feed, and a tab badge is that tab's part of it.
        case .broadcasts: return GlobalNotificationCenter.shared.unreadCount(for: .broadcast)
        default: return 0
        }
    }

    /// Capped in the LABEL, not in the stored count: the real number survives a long absence and
    /// only its rendering is abbreviated. Three characters is as wide as a badge goes before it
    /// starts crowding whatever it sits on.
    static func label(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}
