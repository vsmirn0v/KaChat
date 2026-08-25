import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// A connected Nextcloud account (server + login + app password), persisted as one Keychain blob.
struct NextcloudAccount: Codable, Equatable {
    var serverURLString: String
    var username: String
    var appPassword: String
    /// Where "Send from Nextcloud" starts browsing — nil means the files root. Optional so
    /// blobs stored before this field existed still decode.
    var defaultFolder: String? = nil
    /// Where message backups upload — nil means the default "KaChat" folder at the files root.
    var backupFolder: String? = nil

    var serverURL: URL? { URL(string: serverURLString) }
    var displayName: String {
        let host = URL(string: serverURLString)?.host ?? serverURLString
        return "\(username)@\(host)"
    }
}

/// One entry from a WebDAV folder listing.
struct NextcloudFile: Identifiable, Equatable {
    /// Path relative to the user's files root, e.g. "Photos/cat.jpg".
    let path: String
    let name: String
    let isDirectory: Bool
    let contentType: String?
    let size: Int64?
    let modified: Date?

    var id: String { path }

    /// Content-Type first, file extension as fallback — servers without a mimetype mapping for
    /// HEIC/MOV and friends report `application/octet-stream`, which would otherwise hide real
    /// media from the picker entirely.
    var isImage: Bool {
        if contentType?.hasPrefix("image/") == true { return true }
        return Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    var isVideo: Bool {
        if contentType?.hasPrefix("video/") == true { return true }
        return Self.videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tiff"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm", "mkv", "avi"]
}

extension Array where Element == NextcloudFile {
    /// The one ordering every Nextcloud listing surface uses: phone-gallery order.
    ///
    /// Folders stay grouped ahead of files (so a folder never lands in the middle of the
    /// thumbnail grid), and within each group entries run newest-first by `getlastmodified`.
    /// Entries whose date the server omitted or that failed to parse sort last rather than
    /// interleaving randomly, and name is the tiebreak so equal timestamps stay deterministic.
    ///
    /// Applied once in `NextcloudService.listFolder`; views only filter, never re-sort.
    func sortedNewestFirst() -> [NextcloudFile] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch (lhs.modified, rhs.modified) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

enum NextcloudError: LocalizedError {
    case invalidServerURL
    case badCredentials
    case httpError(Int)
    case malformedResponse
    case backupNotFound
    case noActiveWallet

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "That doesn't look like a valid server URL."
        case .badCredentials:
            return "Nextcloud rejected the username or app password."
        case .noActiveWallet:
            return "Sign in to a KaChat account before connecting Nextcloud."
        case .httpError(let code):
            return "Nextcloud returned HTTP \(code)."
        case .malformedResponse:
            return "Unexpected response from the Nextcloud server."
        case .backupNotFound:
            return "No KaChat backup was found on this Nextcloud server."
        }
    }
}

/// Talks to the user's own Nextcloud server (docs: KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md,
/// "send from Nextcloud" flow): connect with an app password, browse files over WebDAV, and mint
/// public `/s/TOKEN` share links via the OCS API — so chats carry a small link the recipient's
/// link-preview feature renders, instead of pushing file bytes through the on-chain payload.
///
/// Everything here is scoped to the ACTIVE WALLET ACCOUNT, matching desktop: credentials live in
/// a per-wallet Keychain entry (`KeychainService.saveNextcloudCredentials(_:walletAddress:)`),
/// the toggles and throttle stamp in per-wallet UserDefaults keys, and `setCurrentWallet` (called
/// by WalletManager alongside MessageStore and friends) swaps the whole state on account
/// switch/logout so one account's login never leaks into another. The server URL and username
/// aren't secrets but ride along in the same credentials blob for simplicity.
@MainActor
final class NextcloudService: ObservableObject {
    static let shared = NextcloudService()

    @Published private(set) var account: NextcloudAccount?

    /// "Automatic Sync" toggle (Settings > Storage > Nextcloud) - the upgraded form of the old
    /// "Automatic Backup" switch (same stored key, so existing choices carry over; defaults ON
    /// once connected). When on, the shared archive uploads continuously: a debounced merge
    /// upload a few minutes after message activity settles, an hourly on-background catch-up,
    /// and a silent one-time restore when a wallet activates. Per wallet account.
    /// Persistence is NOT in didSet: loads and programmatic defaults must never masquerade as
    /// a user choice (the pre-sync build's didSet did exactly that, stamping OFF on every
    /// wallet load - see `resolveAndMigrateAutoSyncEnabled`). The UI writes through
    /// `setAutoSyncEnabled`, which persists the value plus an explicit-choice marker.
    @Published private(set) var autoBackupEnabled: Bool = false {
        didSet {
            guard !isLoadingWalletState, oldValue != autoBackupEnabled else { return }
            if autoBackupEnabled {
                // Turning sync on marks the archive dirty so the first upload happens promptly,
                // and gives this wallet its one-time silent restore if it never had one.
                noteMessageActivity()
                scheduleAutoRestoreIfNeeded()
            } else {
                syncDebounceTask?.cancel()
                syncDebounceTask = nil
            }
        }
    }

    /// The user flipped the Automatic Sync toggle: persist the value AND the explicit-choice
    /// marker, so this wallet's decision survives every future default resolution.
    ///
    /// One cloud at a time: turning Automatic Sync ON also turns iCloud message storage off
    /// (see `disableICloudMessageSync`); the two sync services are mutually exclusive.
    func setAutoSyncEnabled(_ enabled: Bool) {
        if let key = scopedKey(Self.autoBackupKey) {
            UserDefaults.standard.set(enabled, forKey: key)
        }
        if let markerKey = scopedKey(Self.autoSyncChosenKey) {
            UserDefaults.standard.set(true, forKey: markerKey)
        }
        autoBackupEnabled = enabled
        if enabled {
            disableICloudMessageSync()
        }
    }

    /// Turns iCloud message storage off through the same persisted-settings path the iCloud
    /// toggle uses (`AppSettings.save` + change notification), so every service that watches
    /// the setting sees the flip. The CloudKit store keeps running until its next reload,
    /// exactly as a manual toggle-off does today. The extra nil-object post makes live
    /// `SettingsViewModel` instances reload, so an on-screen iCloud toggle animates off
    /// immediately (saves post WITH the settings object, which those instances deliberately
    /// ignore as their own writes).
    private func disableICloudMessageSync() {
        var settings = AppSettings.load()
        guard settings.storeMessagesInICloud else { return }
        settings.storeMessagesInICloud = false
        AppSettings.save(settings)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        AppLog.log("%@", "[Nextcloud] Automatic Sync enabled; iCloud message storage turned off (one cloud service at a time)")
    }

    /// One-cloud-at-a-time reconciliation for STORED state: if a wallet loads (or connects)
    /// with Nextcloud Automatic Sync on while iCloud message storage is also on - old installs,
    /// or state written before this rule existed - iCloud, the platform default, wins and the
    /// Nextcloud toggle is persisted off. Runs after every `resolveAndMigrateAutoSyncEnabled`
    /// assignment; the explicit-choice marker is left as-is (this is a conflict resolution,
    /// not a user choice).
    private func reconcileOneCloudAtATime() {
        guard autoBackupEnabled, AppSettings.load().storeMessagesInICloud else { return }
        if let key = scopedKey(Self.autoBackupKey) {
            UserDefaults.standard.set(false, forKey: key)
        }
        autoBackupEnabled = false
        AppLog.log("%@", "[Nextcloud] iCloud message storage and Nextcloud Automatic Sync were both enabled; keeping iCloud and turning Nextcloud Automatic Sync off (one cloud service at a time)")
    }

    /// When the active wallet's archive last uploaded automatically (nil = never). Mirrors the
    /// persisted throttle stamp so Settings can show a live "Last synced" line.
    @Published private(set) var lastAutoSyncAt: Date?

    /// Transient status line for the silent auto-restore ("Restored N messages from Nextcloud").
    /// MainTabView renders it as a toast; nil hides it.
    @Published var syncStatusToast: String?

    /// "Send Media via Nextcloud" toggle (Settings > Storage > Nextcloud). When on, photos and
    /// voice recordings sent in 1:1 chats upload to the connected server and the chat message
    /// is the public share link (the recipient's link-preview feature renders it as a native
    /// media bubble / audio card) instead of embedding the bytes in the on-chain payload.
    /// Per wallet account.
    @Published var mediaSendEnabled: Bool = false {
        didSet { persistSetting(mediaSendEnabled, baseKey: Self.mediaSendKey) }
    }

    /// The active wallet's address - every credential/settings read and write is scoped to it.
    /// nil (signed out / no wallet yet) presents as disconnected and persists nothing.
    private(set) var currentWalletAddress: String?
    /// Cached per-wallet suffix (same 8-byte SHA256 hex as the Keychain entry and MessageStore's
    /// zones) for the UserDefaults keys.
    private var currentWalletHashSuffix: String?

    /// The in-flight automatic backup, held so a wallet switch can cancel it - account A's
    /// archive must never upload while account B is active.
    private var autoBackupTask: Task<Void, Never>?

    /// The quiet-time timer armed by `noteMessageActivity` - a rapid exchange coalesces into
    /// one merge upload after things settle. Cancelled by wallet switch, disconnect, toggle-off
    /// and backgrounding (the on-background flush takes over there).
    private var syncDebounceTask: Task<Void, Never>?
    /// The silent one-time restore for a freshly activated wallet.
    private var autoRestoreTask: Task<Void, Never>?
    /// In-memory mirror of the ACTIVE wallet's persisted dirty flag, so the per-message
    /// activity hook doesn't hit UserDefaults on every insert during a big sync.
    private var pendingSyncDirty = false
    /// Serializes automatic uploads and the silent restore so they never interleave; a skipped
    /// run leaves the dirty flag set and a later trigger retries.
    private var syncInFlight = false
    /// True while `setCurrentWallet` loads stored state - suppresses the toggle's user-action
    /// side effects (didSet fires for plain property loads too).
    private var isLoadingWalletState = false

    // `nonisolated` so these constants are usable from nonisolated contexts (e.g. the default
    // argument of autoBackupIfDue) without a main-actor hop — they're immutable Sendable values.
    // Base names only: the active wallet's hash suffix is appended via `scopedKey`.
    private nonisolated static let autoBackupKey = "kachat_nextcloud_auto_backup"
    private nonisolated static let mediaSendKey = "kachat_nextcloud_media_send"
    private nonisolated static let lastAutoBackupKey = "kachat_nextcloud_last_auto_backup"
    /// Persisted dirty flag: message activity happened after the last successful automatic
    /// upload. Survives a kill, so the app-active / on-background catch-up flushes what the
    /// debounce path missed.
    private nonisolated static let pendingSyncKey = "kachat_nextcloud_pending_sync"
    /// Per-wallet marker: this wallet already had its one-time silent auto-restore. Set only
    /// after a successful import; a missing server file leaves it unset so a backup appearing
    /// later (first sync from another device) still bootstraps.
    private nonisolated static let autoRestoreDoneKey = "kachat_nextcloud_auto_restore_done"
    /// Marks that the stored `autoBackupKey` value is an EXPLICIT user choice (or a settled
    /// migration), not a leftover default - see `resolveAndMigrateAutoSyncEnabled`.
    private nonisolated static let autoSyncChosenKey = "kachat_nextcloud_auto_sync_chosen"
    nonisolated static let autoBackupMinInterval: TimeInterval = 3600
    /// Quiet time after the last message before the automatic merge upload runs.
    nonisolated static let syncDebounceInterval: TimeInterval = 180
    /// Launch/foreground catch-up threshold: if the last automatic backup is older than this
    /// (e.g. the app was force-quit for days and never got a backgrounding moment), back up on
    /// becoming active instead of waiting for the next background.
    private nonisolated static let autoBackupCatchUpInterval: TimeInterval = 86_400

    private init() {
        // No credential load here: state stays empty until WalletManager reports the active
        // wallet via setCurrentWallet (every login/switch path calls it).
        // Backgrounding is the natural "done chatting" moment — back up then, inside a
        // background task so iOS gives the upload time to finish.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // The on-background flush takes over from any pending quiet-time timer: the
                // dirty flag is persisted, and autoBackupIfDue bypasses the hourly throttle
                // while it is set, so the pending change uploads inside the background task
                // window instead of waiting out a suspended debounce.
                NextcloudService.shared.syncDebounceTask?.cancel()
                NextcloudService.shared.syncDebounceTask = nil
                NextcloudService.shared.scheduleAutoBackup()
            }
        }
        // Catch-up on launch/foreground: covers users who never background the app cleanly
        // (force-quit, crash, days of disuse). The day-long threshold keeps this from ever
        // competing with the normal hourly on-background cadence.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NextcloudService.shared.scheduleAutoBackup(minInterval: Self.autoBackupCatchUpInterval)
            }
        }
    }

    // MARK: - Wallet scoping

    /// Points the service at `walletAddress`'s stored Nextcloud state, or clears everything for
    /// nil. Called by WalletManager on every wallet load, account switch, logout and delete -
    /// the same hook MessageStore/BroadcastService/etc. use. Cancels any in-flight automatic
    /// backup first, and drops the thumbnail cache so the picker never shows a previous
    /// account's server content.
    func setCurrentWallet(_ walletAddress: String?) {
        guard walletAddress != currentWalletAddress else { return }

        autoBackupTask?.cancel()
        autoBackupTask = nil
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        autoRestoreTask?.cancel()
        autoRestoreTask = nil
        thumbnailCache.removeAllObjects()

        currentWalletAddress = walletAddress
        currentWalletHashSuffix = walletAddress.map { KeychainService.walletHashSuffix($0) }

        isLoadingWalletState = true
        defer { isLoadingWalletState = false }

        guard let walletAddress else {
            account = nil
            autoBackupEnabled = false
            mediaSendEnabled = false
            pendingSyncDirty = false
            lastAutoSyncAt = nil
            return
        }

        migrateLegacyGlobalStateIfNeeded(for: walletAddress)

        if let data = try? KeychainService.shared.loadNextcloudCredentials(walletAddress: walletAddress) {
            account = try? JSONDecoder().decode(NextcloudAccount.self, from: data)
        } else {
            account = nil
        }
        autoBackupEnabled = resolveAndMigrateAutoSyncEnabled()
        reconcileOneCloudAtATime()
        mediaSendEnabled = scopedKey(Self.mediaSendKey).map { UserDefaults.standard.bool(forKey: $0) } ?? false
        pendingSyncDirty = scopedKey(Self.pendingSyncKey).map { UserDefaults.standard.bool(forKey: $0) } ?? false
        let lastStamp = scopedKey(Self.lastAutoBackupKey).map { UserDefaults.standard.double(forKey: $0) } ?? 0
        lastAutoSyncAt = lastStamp > 0 ? Date(timeIntervalSince1970: lastStamp) : nil

        // Wallet activation (load, import, switch) is the auto-restore moment: if the shared
        // file exists and this wallet never restored it, import it silently in the background.
        scheduleAutoRestoreIfNeeded()
    }

    /// Deletes a wallet's stored Nextcloud login and settings outright - used when that account
    /// is removed from this device entirely (WalletManager account deletion flows). Storage
    /// only; the in-memory state is cleared by the setCurrentWallet(nil) that always follows.
    func purgeStoredState(forWalletAddress walletAddress: String) {
        try? KeychainService.shared.deleteNextcloudCredentials(walletAddress: walletAddress)
        let suffix = KeychainService.walletHashSuffix(walletAddress)
        for base in [Self.autoBackupKey, Self.mediaSendKey, Self.lastAutoBackupKey,
                     Self.pendingSyncKey, Self.autoRestoreDoneKey, Self.autoSyncChosenKey] {
            UserDefaults.standard.removeObject(forKey: "\(base)_\(suffix)")
        }
    }

    /// The active wallet's UserDefaults key for `base`, or nil when signed out (in which case
    /// nothing is read or written).
    private func scopedKey(_ base: String) -> String? {
        guard let suffix = currentWalletHashSuffix else { return nil }
        return "\(base)_\(suffix)"
    }

    private func persistSetting(_ value: Bool, baseKey: String) {
        guard let key = scopedKey(baseKey) else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// The active wallet's effective Automatic Sync value, upgrading the old "Automatic
    /// Backup" storage in place the first time this wallet is seen CONNECTED:
    ///
    ///   * explicit-choice marker set: the stored value is authoritative;
    ///   * stored true (the old toggle was on): stays on;
    ///   * stored false with a real backup stamp: the old toggle ran backups and was then
    ///     turned off - that is a genuine choice, kept off;
    ///   * stored false with NO stamp: the pre-sync didSet persisted the OFF default on
    ///     every wallet load, so this is no choice at all - upgraded to the new connected
    ///     default (ON), like a missing value.
    ///
    /// The resolution is persisted with the marker (one-time), so the first successful sync
    /// changing the stamp can never flip the toggle back later. Disconnected wallets are NOT
    /// migrated - the default only means something once a server is connected - and simply
    /// report their stored value.
    private func resolveAndMigrateAutoSyncEnabled() -> Bool {
        guard let key = scopedKey(Self.autoBackupKey),
              let markerKey = scopedKey(Self.autoSyncChosenKey) else { return false }
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: key) as? Bool
        if defaults.bool(forKey: markerKey) {
            return stored ?? (account != nil)
        }
        guard account != nil else { return stored ?? false }

        let resolved: Bool
        if let stored, stored {
            resolved = true
        } else if stored == false,
                  let stampKey = scopedKey(Self.lastAutoBackupKey),
                  defaults.double(forKey: stampKey) > 0 {
            resolved = false
        } else {
            // No real choice on record: the connected default is ON - unless iCloud message
            // storage is already on. One cloud at a time: having iCloud on is an implicit
            // choice against Nextcloud Automatic Sync, so the migration must never silently
            // default it on underneath iCloud.
            resolved = !AppSettings.load().storeMessagesInICloud
        }
        defaults.set(resolved, forKey: key)
        defaults.set(true, forKey: markerKey)
        return resolved
    }

    /// One-time migration off the pre-per-wallet storage: the single global Keychain blob and
    /// the three global UserDefaults keys move to the active wallet's scoped entries - the
    /// account that was actually using the login keeps it - then the global entries are deleted
    /// so no other account ever sees them again.
    private func migrateLegacyGlobalStateIfNeeded(for walletAddress: String) {
        var migratedAnything = false
        let defaults = UserDefaults.standard

        if let legacyBlob = try? KeychainService.shared.loadLegacyNextcloudCredentials() {
            let hasScoped = (try? KeychainService.shared.loadNextcloudCredentials(walletAddress: walletAddress)) != nil
            if !hasScoped {
                try? KeychainService.shared.saveNextcloudCredentials(legacyBlob, walletAddress: walletAddress)
            }
            try? KeychainService.shared.deleteLegacyNextcloudCredentials()
            migratedAnything = true
        }

        for base in [Self.autoBackupKey, Self.mediaSendKey, Self.lastAutoBackupKey] {
            guard let legacyValue = defaults.object(forKey: base), let scoped = scopedKey(base) else { continue }
            if defaults.object(forKey: scoped) == nil {
                defaults.set(legacyValue, forKey: scoped)
            }
            defaults.removeObject(forKey: base)
            migratedAnything = true
        }

        if migratedAnything {
            AppLog.log("%@", "[Nextcloud] Migrated the global Nextcloud login/settings to the active wallet's per-account storage")
        }
    }

    // MARK: - Automatic backup

    /// Runs `autoBackupIfDue` inside a service-owned task so `setCurrentWallet` can cancel it
    /// mid-flight on an account switch.
    private func scheduleAutoBackup(minInterval: TimeInterval = NextcloudService.autoBackupMinInterval) {
        autoBackupTask?.cancel()
        autoBackupTask = Task { [weak self] in
            await self?.autoBackupIfDue(minInterval: minInterval)
        }
    }

    /// Runs the automatic backup when enabled, connected, and either at least `minInterval`
    /// past the last one (hourly for on-background, daily for the launch catch-up) or when the
    /// persisted dirty flag says message activity is still owed an upload (a kill beat the
    /// debounce timer). Failures are silent by design (the flag is re-marked and the next
    /// trigger retries); success stamps the throttle clock and clears the flag. Every upload
    /// goes through `runBackup`, so it merges with the server's copy exactly like a manual one.
    func autoBackupIfDue(minInterval: TimeInterval = NextcloudService.autoBackupMinInterval) async {
        guard autoBackupEnabled, isConnected,
              let walletAtStart = currentWalletAddress,
              let lastBackupKey = scopedKey(Self.lastAutoBackupKey) else { return }
        let last = UserDefaults.standard.double(forKey: lastBackupKey)
        let due = Date().timeIntervalSince1970 - last >= minInterval
        guard due || pendingSyncDirty else { return }

        await performAutomaticSync(walletAtStart: walletAtStart)
    }

    // MARK: - Continuous sync (debounced message-activity uploads)

    /// Message activity signal - called from `ChatService.addMessageToConversation` for every
    /// message that lands, incoming or outgoing, whatever the path. Marks the active wallet's
    /// archive dirty (persisted, so a kill can't lose the fact that an upload is owed) and
    /// restarts the quiet-time timer; a rapid exchange coalesces into one merge upload after
    /// things settle. Cheap and safe to call at any rate.
    func noteMessageActivity() {
        guard autoBackupEnabled, isConnected, let wallet = currentWalletAddress else { return }
        if !pendingSyncDirty {
            pendingSyncDirty = true
            if let key = scopedKey(Self.pendingSyncKey) {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        armSyncDebounce(for: wallet, after: Self.syncDebounceInterval)
    }

    private func armSyncDebounce(for wallet: String, after delay: TimeInterval) {
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.pendingSyncDirty else { return }
            await self.performAutomaticSync(walletAtStart: wallet)
        }
    }

    /// The one automatic upload path. `walletAtStart` is the wallet snapshotted at schedule
    /// time; the active wallet is re-checked before building and again before uploading (inside
    /// `runBackup`), so a wallet switch mid-flight drops the work instead of writing one
    /// account's history into another's file. The dirty flag is cleared BEFORE building - a
    /// message arriving during the upload re-marks it, so nothing is lost; clearing after would
    /// swallow that signal - and re-marked on any failure so a later trigger retries.
    private func performAutomaticSync(walletAtStart: String) async {
        guard currentWalletAddress == walletAtStart, autoBackupEnabled, isConnected else { return }
        guard !syncInFlight,
              !BackupRestoreCoordinator.shared.isRunning,
              !IncomingResyncCoordinator.shared.isRunning else {
            // A manual restore/resync (or another automatic pass) owns the store right now;
            // the dirty flag stays set and a short re-arm retries once it is done.
            armSyncDebounce(for: walletAtStart, after: 30)
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        setPendingSyncDirty(false, walletAddress: walletAtStart)

        let taskId = UIApplication.shared.beginBackgroundTask(withName: "nextcloud-auto-backup")
        defer { if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) } }

        do {
            try await runBackup()
            guard !Task.isCancelled, currentWalletAddress == walletAtStart else { return }
            let now = Date()
            if let lastBackupKey = scopedKey(Self.lastAutoBackupKey) {
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastBackupKey)
            }
            lastAutoSyncAt = now
            AppLog.log("%@", "[Nextcloud] Automatic sync uploaded the merged archive")
        } catch {
            setPendingSyncDirty(true, walletAddress: walletAtStart)
            AppLog.log("%@", "[Nextcloud] Automatic sync upload failed (a later trigger retries): \(error.localizedDescription)")
        }
    }

    /// Writes the dirty flag against a SNAPSHOTTED wallet's scoped key (never the current
    /// one - the wallet may have switched mid-flight) and keeps the in-memory mirror in step
    /// when that wallet is still active.
    private func setPendingSyncDirty(_ dirty: Bool, walletAddress: String) {
        let key = "\(Self.pendingSyncKey)_\(KeychainService.walletHashSuffix(walletAddress))"
        UserDefaults.standard.set(dirty, forKey: key)
        if currentWalletAddress == walletAddress {
            pendingSyncDirty = dirty
        }
    }

    // MARK: - Automatic restore (one-time silent bootstrap per wallet)

    /// Arms the silent restore for the active wallet if it never had one. Runs a few seconds
    /// later so wallet activation (message store switch, chat list load) finishes first; the
    /// wallet is re-checked at every await. No modal for this path - one log line and a short
    /// toast with counts.
    func scheduleAutoRestoreIfNeeded() {
        guard isConnected, autoBackupEnabled, let wallet = currentWalletAddress,
              let doneKey = scopedKey(Self.autoRestoreDoneKey),
              !UserDefaults.standard.bool(forKey: doneKey) else { return }
        autoRestoreTask?.cancel()
        autoRestoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runAutoRestore(walletAtStart: wallet)
        }
    }

    private func runAutoRestore(walletAtStart: String) async {
        guard currentWalletAddress == walletAtStart, isConnected, autoBackupEnabled else { return }
        // The manual restore/resync modals own the store while running; skip silently (the
        // done flag stays unset, so the next wallet activation retries).
        guard !BackupRestoreCoordinator.shared.isRunning,
              !IncomingResyncCoordinator.shared.isRunning,
              !syncInFlight else { return }
        let doneKey = "\(Self.autoRestoreDoneKey)_\(KeychainService.walletHashSuffix(walletAtStart))"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        syncInFlight = true
        defer { syncInFlight = false }

        do {
            // Envelope-aware: decrypts a v1 encrypted backup, passes legacy plaintext through.
            // A failed decrypt throws into the silent catch below - the done flag stays unset
            // and nothing is imported or uploaded.
            let data = try BackupEnvelope.decryptIfEnveloped(
                try await downloadBackup(), key: backupEncryptionKey(), walletAddress: walletAtStart
            )
            guard !Task.isCancelled, currentWalletAddress == walletAtStart,
                  !BackupRestoreCoordinator.shared.isRunning,
                  !IncomingResyncCoordinator.shared.isRunning else { return }
            let summary = try await ChatService.shared.importChatHistoryArchive(data)
            guard currentWalletAddress == walletAtStart else { return }
            UserDefaults.standard.set(true, forKey: doneKey)
            // Fully silent by design: sync is invisible background plumbing, like iCloud.
            // The log line is the only trace.
            AppLog.log("%@", "[Nextcloud] Automatic restore finished: \(summary.messageCount) messages in \(summary.conversationCount) chats")
        } catch NextcloudError.backupNotFound {
            // No file yet is not an error, and does NOT mark restore done: if a backup appears
            // later (first sync from another device), the next activation picks it up.
        } catch {
            // Includes "archive invalid/empty" and transient network failures: stay silent
            // (the flag stays unset, so a later activation retries) and never surface a modal.
            AppLog.log("%@", "[Nextcloud] Automatic restore skipped (next wallet activation retries): \(error.localizedDescription)")
        }
    }

    private func showSyncToast(_ message: String) {
        withAnimation { syncStatusToast = message }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.syncStatusToast == message else { return }
            withAnimation { self.syncStatusToast = nil }
        }
    }

    var isConnected: Bool { account != nil }

    /// Normalizes user input ("restohome.duckdns.org", trailing slashes, an accidental
    /// "/index.php" suffix) into a clean base URL, defaulting to https.
    nonisolated static func normalizedServerURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.lowercased().hasSuffix("/index.php") { raw.removeLast("/index.php".count) }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    /// Verifies the credentials against the OCS user endpoint (the cheapest authenticated call),
    /// then persists them. Throws `badCredentials` on a 401 so the connect screen can say exactly
    /// what's wrong.
    func connect(serverInput: String, username: String, appPassword: String) async throws {
        guard let walletAddress = currentWalletAddress else {
            throw NextcloudError.noActiveWallet
        }
        guard let server = Self.normalizedServerURL(from: serverInput) else {
            throw NextcloudError.invalidServerURL
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { throw NextcloudError.badCredentials }

        let candidate = NextcloudAccount(serverURLString: server.absoluteString, username: user, appPassword: password)
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/cloud/user?format=json") else {
            throw NextcloudError.invalidServerURL
        }
        var request = URLRequest(url: endpoint)
        applyAuth(&request, account: candidate)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              ocs["data"] is [String: Any] else {
            throw NextcloudError.malformedResponse
        }

        let encoded = try JSONEncoder().encode(candidate)
        try KeychainService.shared.saveNextcloudCredentials(encoded, walletAddress: walletAddress)
        account = candidate

        // Automatic Sync defaults ON for a fresh connection (an earlier explicit choice for
        // this wallet carries over instead), the archive is marked dirty so the first upload
        // happens promptly, and the wallet gets its one-time silent restore if the shared
        // file already exists.
        autoBackupEnabled = resolveAndMigrateAutoSyncEnabled()
        reconcileOneCloudAtATime()
        noteMessageActivity()
        scheduleAutoRestoreIfNeeded()
    }

    func disconnect() {
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
        autoRestoreTask?.cancel()
        autoRestoreTask = nil
        autoBackupTask?.cancel()
        autoBackupTask = nil
        if let walletAddress = currentWalletAddress {
            try? KeychainService.shared.deleteNextcloudCredentials(walletAddress: walletAddress)
        }
        // Belt and braces: if a legacy global blob somehow still exists, remove it too so
        // disconnect can never appear to "come back" via migration.
        try? KeychainService.shared.deleteLegacyNextcloudCredentials()
        account = nil
    }

    /// Persists the picker's start folder (nil/"" = files root) into the credentials blob.
    func setDefaultFolder(_ path: String?) {
        guard var updated = account else { return }
        let clean = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.defaultFolder = (clean?.isEmpty ?? true) ? nil : clean
        persistAccountBlob(updated)
        account = updated
    }

    /// Persists the backup destination folder (nil/"" = the default "KaChat" folder).
    func setBackupFolder(_ path: String?) {
        guard var updated = account else { return }
        let clean = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.backupFolder = (clean?.isEmpty ?? true) ? nil : clean
        persistAccountBlob(updated)
        account = updated
    }

    private func persistAccountBlob(_ updated: NextcloudAccount) {
        guard let walletAddress = currentWalletAddress,
              let encoded = try? JSONEncoder().encode(updated) else { return }
        try? KeychainService.shared.saveNextcloudCredentials(encoded, walletAddress: walletAddress)
    }

    /// The folder backups actually go to — the user's chosen folder, or "KaChat" by default.
    var backupFolderPath: String {
        account?.backupFolder ?? Self.backupFolderName
    }

    // MARK: - Thumbnails (the picker's photo grid)

    /// In-memory only — thumbnails are cheap to refetch and shouldn't outlive the session.
    private let thumbnailCache = NSCache<NSString, NSData>()

    /// Server-generated square thumbnail via Nextcloud's authenticated `core/preview` endpoint
    /// (`a=1` keeps aspect by cropping). Works for images everywhere and for videos when the
    /// server has a video preview provider; nil on any failure (the grid shows an icon).
    func thumbnailData(for path: String, size: Int = 256) async -> Data? {
        guard let account, let server = account.serverURL else { return nil }
        if let cached = thumbnailCache.object(forKey: path as NSString) { return cached as Data }
        guard var components = URLComponents(url: server.appendingPathComponent("index.php/core/preview.png"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "file", value: "/" + path),
            URLQueryItem(name: "x", value: String(size)),
            URLQueryItem(name: "y", value: String(size)),
            URLQueryItem(name: "a", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        applyAuth(&request, account: account)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        thumbnailCache.setObject(data as NSData, forKey: path as NSString)
        return data
    }

    /// Lets the picker cache a client-side generated thumbnail (HEIC decode / video frame grab)
    /// alongside the server-generated ones.
    func storeThumbnail(_ data: Data, for path: String) {
        thumbnailCache.setObject(data as NSData, forKey: path as NSString)
    }

    /// Authenticated GET request for a file's raw bytes over WebDAV — used by the thumbnail
    /// fallbacks when the server can't generate a preview (HEIC without ImageMagick, MOV
    /// without ffmpeg).
    func authenticatedFileRequest(for path: String) -> URLRequest? {
        guard let account, let server = account.serverURL else { return nil }
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(path)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        var request = URLRequest(url: url)
        applyAuth(&request, account: account)
        return request
    }

    /// Full file bytes over WebDAV, size-capped — the HEIC thumbnail fallback decodes these
    /// locally (iOS reads HEIC natively even when the server can't).
    func fileData(for path: String, maxBytes: Int = 25_000_000) async -> Data? {
        guard let request = authenticatedFileRequest(for: path) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    // MARK: - Chat-history backup (WebDAV PUT/GET of the archive JSON)

    static let backupFolderName = "KaChat"
    static let backupFileName = "kachat-backup.json"

    /// The whole backup: read whatever the server already holds, merge it with this device's
    /// history (`ChatService.buildBackupArchiveData`), and upload the union - so a backup can
    /// only ever ADD to `kachat-backup.json` (desktop, iOS and Android all write that same
    /// file) and no device can delete another's chat history. Every path that backs chat
    /// history up must go through here, never a raw `uploadBackup`.
    ///
    /// The only "just upload" case is a genuine 404 (no backup yet). Every other failure - an
    /// unreadable server response, or a merge that rejects the remote file as foreign, corrupt
    /// or a different wallet - throws BEFORE the PUT, leaving the existing file untouched. The
    /// active wallet is re-checked around every await so a mid-flight account switch aborts
    /// instead of cross-pollinating archives.
    func runBackup() async throws {
        let walletAtStart = currentWalletAddress
        // Encryption key up front: writers ALWAYS encrypt (see BackupEnvelope), so if the
        // identity key is unavailable the backup is skipped rather than uploaded readable.
        guard let walletAddress = walletAtStart, let key = backupEncryptionKey() else {
            throw BackupEnvelope.EnvelopeError.keyUnavailable
        }
        let existing: Data?
        do {
            // A failed decrypt (wrong seed's file, corrupt envelope) throws HERE - before the
            // merge and before any PUT - so the server copy is never overwritten.
            existing = try BackupEnvelope.decryptIfEnveloped(
                try await downloadBackup(), key: key, walletAddress: walletAddress
            )
        } catch NextcloudError.backupNotFound {
            existing = nil
        }
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }
        let merged = try await ChatService.shared.buildBackupArchiveData(mergingRemote: existing)
        guard !Task.isCancelled, currentWalletAddress == walletAtStart else { throw CancellationError() }
        try await uploadBackup(try BackupEnvelope.encrypt(merged, key: key, walletAddress: walletAddress))
    }

    /// The active wallet's backup envelope key, derived from the chatting/identity address's
    /// raw private key (`WalletManager.getPrivateKey()` - the same key the wallet already
    /// holds; never re-derived from the seed here). Nil when no wallet key is loadable.
    fileprivate func backupEncryptionKey() -> SymmetricKey? {
        guard let identityKey = WalletManager.shared.getPrivateKey() else { return nil }
        return BackupEnvelope.key(identityPrivateKey: identityKey)
    }

    /// Uploads the archive to `<backup folder>/kachat-backup.json`, creating the folder first
    /// (MKCOL answers 405 when it already exists — fine; a user-picked folder always already
    /// exists since it was chosen through the folder browser). Overwrites in place: private so
    /// every chat-history caller goes through `runBackup` and the body is a merge, never a
    /// replacement.
    private func uploadBackup(_ data: Data) async throws {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        for part in backupFolderPath.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
        }

        var mkcol = URLRequest(url: folderURL)
        mkcol.httpMethod = "MKCOL"
        applyAuth(&mkcol, account: account)
        let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
        if let http = mkcolResponse as? HTTPURLResponse {
            if http.statusCode == 401 { throw NextcloudError.badCredentials }
            guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                throw NextcloudError.httpError(http.statusCode)
            }
        }

        var put = URLRequest(url: folderURL.appendingPathComponent(Self.backupFileName))
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
    }

    /// The backup file's server-side metadata (nil = no backup yet). A missing folder lists
    /// as a 404, which also just means "no backup yet".
    func fetchBackupInfo() async -> NextcloudFile? {
        guard let listing = try? await listFolder(backupFolderPath) else { return nil }
        return listing.first { $0.name == Self.backupFileName && !$0.isDirectory }
    }

    /// Downloads the backup archive bytes. 404 -> `backupNotFound`.
    /// `progress` (optional) streams `(bytesReceived, totalBytesExpected)` as the body downloads;
    /// `totalBytesExpected` is nil when the server omits Content-Length. It is invoked OFF the
    /// main actor (the byte accumulation runs nonisolated so a large archive never stalls UI),
    /// so callers must hop to the main actor themselves.
    func downloadBackup(progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> Data {
        guard let request = authenticatedFileRequest(for: "\(backupFolderPath)/\(Self.backupFileName)") else {
            throw NextcloudError.badCredentials
        }
        return try await Self.performBackupDownload(request: request, progress: progress)
    }

    private nonisolated static func performBackupDownload(
        request: URLRequest,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if http.statusCode == 404 { throw NextcloudError.backupNotFound }
        guard (200..<300).contains(http.statusCode) else {
            throw NextcloudError.httpError(http.statusCode)
        }

        let expected: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        var data = Data()
        if let expected { data.reserveCapacity(Int(expected)) }
        // Throttle progress to every 64KB so a big archive doesn't flood the main actor.
        let reportStride: Int64 = 65_536
        var lastReported: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            if let progress {
                let count = Int64(data.count)
                if count - lastReported >= reportStride {
                    lastReported = count
                    progress(count, expected)
                }
            }
        }
        guard !data.isEmpty else { throw NextcloudError.httpError(http.statusCode) }
        progress?(Int64(data.count), expected)
        return data
    }

    // MARK: - Media send (chat photos/voice notes uploaded as public share links)

    /// Fixed upload destination for chat media — intentionally independent of the user-chosen
    /// backup folder so media never lands inside a folder the user picked for archives.
    nonisolated static let mediaFolderPath = "KaChat/Media"

    /// Uploads one media file to `KaChat/Media/` and returns a public `/s/TOKEN` share link for
    /// it — the exact URL form the recipient's link-preview feature renders as a media bubble.
    /// The folder chain is created level by level (MKCOL is not recursive; 405 means "already
    /// exists", same convention as `uploadBackup`). An 8-char random prefix on the stored name
    /// keeps same-second filenames (photo_20260811-101502.jpg twice) from overwriting each other.
    func uploadMediaAndShare(data: Data, filename: String, contentType: String) async throws -> URL {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }

        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        for part in Self.mediaFolderPath.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
            var mkcol = URLRequest(url: folderURL)
            mkcol.httpMethod = "MKCOL"
            applyAuth(&mkcol, account: account)
            let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
            if let http = mkcolResponse as? HTTPURLResponse {
                if http.statusCode == 401 { throw NextcloudError.badCredentials }
                guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                    throw NextcloudError.httpError(http.statusCode)
                }
            }
        }

        let storedName = "\(UUID().uuidString.prefix(8))_\(Self.sanitizedMediaFilename(filename))"
        var put = URLRequest(url: folderURL.appendingPathComponent(storedName))
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }

        return try await createPublicShareLink(for: "\(Self.mediaFolderPath)/\(storedName)")
    }

    /// Keeps stored filenames WebDAV/URL-safe: alphanumerics, dot, dash and underscore survive;
    /// everything else becomes "_". The extension must survive intact — Nextcloud derives the
    /// Content-Type it serves (and thus the recipient's media-kind detection) from it.
    private nonisolated static func sanitizedMediaFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "file" : cleaned
    }

    private nonisolated func applyAuth(_ request: inout URLRequest, account: NextcloudAccount) {
        let token = Data("\(account.username):\(account.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - WebDAV browsing (the chat attach picker's data source)

    /// Lists one folder (non-recursive) of the connected account's files via a Depth-1 PROPFIND.
    func listFolder(_ relativePath: String = "") async throws -> [NextcloudFile] {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let davBasePath = "/remote.php/dav/files/\(account.username)"
        // Normalized form of the listed folder, for the parser's self-entry exclusion below.
        let listedPath = relativePath.split(separator: "/").joined(separator: "/")
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(relativePath)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, account: account)
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/></d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard http.statusCode == 207 else { throw NextcloudError.httpError(http.statusCode) }

        return DavMultistatusParser(davBasePath: davBasePath, listedPath: listedPath)
            .parse(data)
            .sortedNewestFirst()
    }

    // MARK: - Public share links (OCS files_sharing API)

    /// Creates a public link share (shareType 3) for `relativePath` and returns its `/s/TOKEN`
    /// URL — the exact form the link-preview feature renders. If the file already has a public
    /// link (creating again can fail on some configs), the existing link is reused.
    func createPublicShareLink(for relativePath: String) async throws -> URL {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json") else {
            throw NextcloudError.invalidServerURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyAuth(&request, account: account)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("path=\(Self.formEncoded("/" + relativePath))&shareType=3".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if (200..<300).contains(http.statusCode),
           let url = Self.shareURL(fromOCSObject: data) {
            return url
        }
        if let existing = try await existingPublicShareLink(for: relativePath) { return existing }
        throw NextcloudError.malformedResponse
    }

    private func existingPublicShareLink(for relativePath: String) async throws -> URL? {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let path = Self.formEncoded("/" + relativePath)
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json&path=\(path)") else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        applyAuth(&request, account: account)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              let list = ocs["data"] as? [[String: Any]] else { return nil }
        for share in list where (share["share_type"] as? Int) == 3 {
            if let urlString = share["url"] as? String, let url = URL(string: urlString) { return url }
        }
        return nil
    }

    private nonisolated static func shareURL(fromOCSObject data: Data) -> URL? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              let payload = ocs["data"] as? [String: Any],
              let urlString = payload["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    private nonisolated static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Minimal WebDAV `multistatus` parser for folder listings — pulls each response's href,
/// display name, collection flag, content type and length. Namespace-agnostic via
/// `shouldProcessNamespaces` (servers vary between `d:` and `D:` prefixes).
private final class DavMultistatusParser: NSObject, XMLParserDelegate {
    private let davBasePath: String
    /// The folder being listed. A Depth-1 PROPFIND's multistatus includes the listed folder
    /// ITSELF as its first response — without excluding it, every folder appears to contain
    /// itself (an infinite "Photos inside Photos" loop when browsing).
    private let listedPath: String
    private var results: [NextcloudFile] = []
    private var inResponse = false
    private var currentHref = ""
    private var currentName: String?
    private var currentType: String?
    private var currentLength: Int64?
    private var currentModified: Date?
    private var isCollection = false
    private var text = ""

    /// WebDAV's getlastmodified is RFC 1123 ("Mon, 11 Aug 2026 20:14:07 GMT").
    private static let lastModifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        // The string carries its own zone ("GMT"), but pin the fallback so a server that omits it
        // is read as UTC instead of drifting with the device's local zone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(davBasePath: String, listedPath: String) {
        self.davBasePath = davBasePath
        self.listedPath = listedPath
    }

    func parse(_ data: Data) -> [NextcloudFile] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            inResponse = true
            currentHref = ""
            currentName = nil
            currentType = nil
            currentLength = nil
            currentModified = nil
            isCollection = false
        case "collection":
            isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if inResponse, currentHref.isEmpty { currentHref = trimmed }
        case "displayname":
            if inResponse, currentName == nil, !trimmed.isEmpty { currentName = trimmed }
        case "getcontenttype":
            if inResponse, !trimmed.isEmpty { currentType = trimmed }
        case "getcontentlength":
            if inResponse { currentLength = Int64(trimmed) }
        case "getlastmodified":
            if inResponse, !trimmed.isEmpty { currentModified = Self.lastModifiedFormatter.date(from: trimmed) }
        case "response":
            inResponse = false
            appendCurrent()
        default:
            break
        }
    }

    private func appendCurrent() {
        guard let decoded = currentHref.removingPercentEncoding,
              let range = decoded.range(of: davBasePath) else { return }
        var relative = String(decoded[range.upperBound...])
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        guard !relative.isEmpty, relative != listedPath else { return } // the listed folder itself
        let fallbackName = relative.split(separator: "/").last.map(String.init) ?? relative
        results.append(NextcloudFile(
            path: relative,
            name: currentName ?? fallbackName,
            isDirectory: isCollection,
            contentType: currentType,
            size: currentLength,
            modified: currentModified
        ))
    }
}

// MARK: - Encrypted backup envelope (v1)

/// At-rest encryption for the shared Nextcloud `kachat-backup.json` - the exact cross-platform
/// format specified in MESSAGING.md ("Encrypted Backup Envelope (v1)"). AES-256-GCM via
/// CryptoKit; the key is SHA-256(identity private key raw 32 bytes || "kachat-backup-v1"), so
/// any device holding the seed derives the same key and nothing else can read the archive.
/// Writers ALWAYS encrypt; readers detect the envelope and fall back to legacy plaintext
/// parsing, so old backups stay restorable indefinitely. iCloud/CloudKit is untouched.
enum BackupEnvelope {
    struct Envelope: Codable {
        let kachatEncryptedBackup: Int
        let cipher: String
        let nonce: String
        let ciphertext: String
        let walletHint: String?
    }

    enum EnvelopeError: LocalizedError {
        case decryptFailed
        case keyUnavailable

        var errorDescription: String? {
            switch self {
            case .decryptFailed:
                return "Could not decrypt the backup. It may belong to a different account."
            case .keyUnavailable:
                return "The wallet key needed to encrypt the backup is not available."
            }
        }
    }

    /// key = SHA-256(identity_private_key_bytes || UTF8("kachat-backup-v1")) - the identity key
    /// is the chatting address's raw 32-byte private key (`WalletManager.getPrivateKey()`).
    static func key(identityPrivateKey: Data) -> SymmetricKey {
        var material = identityPrivateKey
        material.append(Data("kachat-backup-v1".utf8))
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    /// First 8 bytes of SHA-256(walletAddress) as hex - identical to
    /// `KeychainService.walletHashSuffix`, restated here so this codec stays self-contained.
    static func walletHint(for walletAddress: String) -> String {
        SHA256.hash(data: Data(walletAddress.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Wraps the plaintext archive in the v1 envelope: fresh random 12-byte nonce per write,
    /// ciphertext carries the 16-byte GCM tag appended, both base64.
    static func encrypt(_ plaintext: Data, key: SymmetricKey, walletAddress: String) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce())
        let envelope = Envelope(
            kachatEncryptedBackup: 1,
            cipher: "aes-256-gcm",
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString(),
            walletHint: walletHint(for: walletAddress)
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Detects the v1 envelope. The literal-marker scan keeps legacy multi-MB archives cheap
    /// (no full JSON decode attempt); a legacy archive that happens to CONTAIN the marker text
    /// inside a message simply fails the decode and is treated as plaintext.
    static func parse(_ data: Data) -> Envelope? {
        guard data.range(of: Data("\"kachatEncryptedBackup\"".utf8)) != nil,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kachatEncryptedBackup == 1 else { return nil }
        return envelope
    }

    /// Envelope-aware read: legacy plaintext passes through untouched; a v1 envelope is
    /// decrypted (after a cheap walletHint check that skips a foreign wallet's file without
    /// attempting the decrypt). Any failure throws `decryptFailed` - callers abort BEFORE any
    /// upload, so a wrong-seed or corrupt file can never overwrite the server copy.
    static func decryptIfEnveloped(_ data: Data, key: SymmetricKey?, walletAddress: String?) throws -> Data {
        guard let envelope = parse(data) else { return data }
        if let hint = envelope.walletHint, let walletAddress, hint != walletHint(for: walletAddress) {
            throw EnvelopeError.decryptFailed
        }
        guard let key,
              envelope.cipher == "aes-256-gcm",
              let nonceData = Data(base64Encoded: envelope.nonce),
              let combined = Data(base64Encoded: envelope.ciphertext),
              combined.count > 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: combined.dropLast(16), tag: combined.suffix(16)),
              let plaintext = try? AES.GCM.open(sealed, using: key) else {
            throw EnvelopeError.decryptFailed
        }
        return plaintext
    }
}

// MARK: - Backup restore coordinator (blocking progress modal)

/// Owns a chat-history restore from tap to terminal state, independent of any view's lifetime.
/// Interrupting a restore midway can leave local state partially written, so the Settings screens
/// only OBSERVE this singleton: the restore `Task` is held here, never by a view, and view
/// teardown can never cancel it. While `phase == .running` the Settings hierarchy presents a
/// full-screen modal (`ChatRestoreProgressModal` in SettingsView.swift) that cannot be dismissed;
/// the only exits are the modal's own Done / Try Again / Close buttons, which call back into
/// `dismiss()` / `retry()` here, and `dismiss()` refuses to fire while a restore is running.
@MainActor
final class BackupRestoreCoordinator: ObservableObject {
    static let shared = BackupRestoreCoordinator()
    private init() {}

    enum Phase: Equatable {
        case idle
        case running
        case success(conversations: Int, messages: Int, filledSent: Int)
        case failure(String)
    }

    enum Source {
        /// kachat-backup.json downloaded from the connected Nextcloud server.
        case nextcloud
        /// An archive the user picked with the file importer (Settings > Chat History > Import).
        case localArchive(Data)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0...1, monotonic. Stage weights: download 0-30% (real bytes when the server sends
    /// Content-Length), validate/prepare 30-40%, Core Data import 40-90% (advances per
    /// conversation inside MessageStore.syncFromConversations), finalize 90-100%.
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stageText: String = ""

    var isRunning: Bool { phase == .running }
    var isPresentingModal: Bool { phase != .idle }

    /// Kept so Try Again after a failure reruns the exact same restore.
    private var lastSource: Source?
    /// Held by the singleton (not a view) so navigation or sheet dismissal cannot cancel it.
    private var restoreTask: Task<Void, Never>?

    func startNextcloudRestore() { start(.nextcloud) }
    func startLocalRestore(data: Data) { start(.localArchive(data)) }

    /// Reruns the failed restore. Only valid from the failure state.
    func retry() {
        guard case .failure = phase, let lastSource else { return }
        phase = .idle
        start(lastSource)
    }

    /// Leaves the modal. Only honored from a terminal state; a running restore cannot be dismissed.
    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
        fraction = 0
        stageText = ""
    }

    private func start(_ source: Source) {
        guard !isRunning else { return }
        lastSource = source
        fraction = 0
        switch source {
        case .nextcloud: stageText = "Downloading backup..."
        case .localArchive: stageText = "Reading archive..."
        }
        phase = .running
        restoreTask = Task { [weak self] in
            await self?.run(source)
        }
    }

    private func run(_ source: Source) async {
        do {
            let data: Data
            switch source {
            case .nextcloud:
                data = try await NextcloudService.shared.downloadBackup { [weak self] received, expectedTotal in
                    Task { @MainActor [weak self] in
                        guard let self, let expectedTotal, expectedTotal > 0 else { return }
                        let downloaded = min(1.0, Double(received) / Double(expectedTotal))
                        self.advance(to: 0.30 * downloaded, stage: "Downloading backup...")
                    }
                }
                advance(to: 0.30, stage: "Validating backup...")
            case .localArchive(let archiveData):
                data = archiveData
                advance(to: 0.05, stage: "Validating backup...")
            }

            // Envelope-aware for BOTH sources: the Nextcloud file is encrypted at rest (see
            // BackupEnvelope), and a locally picked file may be a hand-copied server backup.
            // Legacy plaintext archives pass through untouched. A failed decrypt lands in the
            // catch below with the clear "different account" message.
            let archive = try BackupEnvelope.decryptIfEnveloped(
                data,
                key: NextcloudService.shared.backupEncryptionKey(),
                walletAddress: WalletManager.shared.currentWallet?.publicAddress
            )

            let summary = try await ChatService.shared.importChatHistoryArchive(archive) { [weak self] event in
                guard let self else { return }
                switch event {
                case .validating:
                    self.advance(to: 0.32, stage: "Validating backup...")
                case .preparing:
                    self.advance(to: 0.36, stage: "Preparing messages...")
                case .importing(let done, let total):
                    let f = total > 0 ? Double(done) / Double(total) : 1.0
                    self.advance(
                        to: 0.40 + 0.50 * f,
                        stage: "Restoring messages... \(done) of \(total) conversations"
                    )
                case .finalizing:
                    self.advance(to: 0.92, stage: "Finishing up...")
                }
            }
            fraction = 1.0
            stageText = "Done"
            // Retry is only offered after a failure; drop the retained archive bytes on success.
            lastSource = nil
            phase = .success(
                conversations: summary.conversationCount,
                messages: summary.messageCount,
                filledSent: summary.filledSentContentCount
            )
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    /// Monotonic progress: overlapping async reports can never move the bar backwards.
    private func advance(to value: Double, stage: String) {
        fraction = max(fraction, min(value, 1.0))
        stageText = stage
    }
}
