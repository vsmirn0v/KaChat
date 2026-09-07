import Foundation

/// Unseen-KaPosts-activity count, kept apart from `GlobalNotificationCenter`.
///
/// KaPosts activity used to be listed in the global center alongside group mentions, broadcasts
/// and wallet events. It does not belong there: KaPosts has its own notifications screen with its
/// own richer rows, so the same like or reply was reported twice, and the profile bell's count was
/// dominated by whichever feed happened to be busiest. The global center no longer keeps KaPosts
/// rows at all; this holds the count that KaPosts itself reports.
///
/// A COUNT, not a feed. The rows are already served by the KaPosts notifications screen straight
/// from the indexer, so storing them a second time would only be a cache that could disagree with
/// it. What cannot be derived from the indexer is how many the user has not looked at yet, which
/// is what this persists.
@MainActor
final class KaPostsNotificationCenter: ObservableObject {
    static let shared = KaPostsNotificationCenter()

    /// How many notifications have arrived since the user last opened the KaPosts bell.
    @Published private(set) var unseenCount: Int = 0

    private init() { reload() }

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var unseenKey: String { "kapostsNotifCenter.unseen.\(walletAddress)" }

    /// Call on account switch (and at init) to load the active wallet's count.
    func reload() {
        unseenCount = max(0, UserDefaults.standard.integer(forKey: unseenKey))
    }

    /// Adds newly-arrived activity to the count. Called from the same ingest pass that used to
    /// write KaPosts rows into the global center, so it inherits its filtering: the wallet's own
    /// actions, hidden actors and Child Mode are all already excluded by the caller.
    func recordArrivals(_ count: Int) {
        guard count > 0 else { return }
        unseenCount += count
        persist()
    }

    /// The user has opened the KaPosts notifications screen; nothing is unseen any more.
    func markAllSeen() {
        guard unseenCount != 0 else { return }
        unseenCount = 0
        persist()
    }

    /// Capped in the label rather than in the stored value, so the real number survives a
    /// long absence and only its rendering is abbreviated.
    var badgeText: String { unseenCount > 99 ? "99+" : "\(unseenCount)" }

    private func persist() {
        UserDefaults.standard.set(unseenCount, forKey: unseenKey)
    }
}
