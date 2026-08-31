import Foundation
import Combine

/// Thread-safe cache for `AppSettings.load()`. Load used to do a UserDefaults read + a fresh
/// JSONDecoder + a full ~25-field decode on EVERY call - and it's called from hot paths (per
/// Kaspa block in the group/broadcast scanners at ~10 blocks/sec, per day-separator render, per
/// API request). Invalidated whenever settings change (`.settingsDidChange` is posted by every
/// write path: `AppSettings.save` and `SettingsViewModel.saveSettings`).
private final class AppSettingsCache: @unchecked Sendable {
    static let shared = AppSettingsCache()
    private let lock = NSLock()
    private var cached: AppSettings?
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }
    func get() -> AppSettings? { lock.lock(); defer { lock.unlock() }; return cached }
    func set(_ settings: AppSettings) { lock.lock(); defer { lock.unlock() }; cached = settings }
    func invalidate() { lock.lock(); defer { lock.unlock() }; cached = nil }
}

/// Per-account dock layout (tab order + which tabs are hidden). The dock is PER ACCOUNT: the
/// same install can hold multiple accounts, each with its own arrangement. Stored as one JSON
/// blob per wallet address; `AppSettings.load()` overlays the active account's blob onto the
/// global settings, and every save writes the current dock fields back to that account's blob.
/// An account with no blob yet inherits the global values (continuity for the account that
/// existed before this feature, a sensible starting point for new ones) and diverges on its
/// first dock change.
struct DockOverlay: Codable {
    var tabOrder: [String]
    var hiddenTabs: [String]
}

/// Extension to load settings from any context (not MainActor-isolated)
extension AppSettings {
    static func dockOverlayKey(for address: String) -> String { "kachat_dock_overlay_\(address)" }

    /// The active wallet address, from the app-group defaults (kept current by
    /// SharedDataManager.syncWalletAddressForExtension on every load/switch/logout) - readable
    /// from any context, unlike the MainActor-bound WalletManager.
    static func activeDockAddress() -> String? {
        (SharedDataManager.sharedDefaultsValue(forKey: "wallet_address") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    mutating func applyDockOverlay(_ overlay: DockOverlay) {
        tabOrder = overlay.tabOrder
        hidePortfolioTab = overlay.hiddenTabs.contains(AppTab.portfolio.rawValue)
        hideColdStorageTab = overlay.hiddenTabs.contains(AppTab.coldStorage.rawValue)
        hideSwapTab = overlay.hiddenTabs.contains(AppTab.swap.rawValue)
        hideKaPostsTab = overlay.hiddenTabs.contains(AppTab.kaposts.rawValue)
        hideBroadcasts = overlay.hiddenTabs.contains(AppTab.broadcasts.rawValue)
        hideAppsTab = overlay.hiddenTabs.contains(AppTab.apps.rawValue)
        hideMoreItem = overlay.hiddenTabs.contains(AppTab.more.rawValue)
    }

    func dockOverlay() -> DockOverlay {
        // Raw hide flags, NOT AppTab.isEnabled: isEnabled also applies the Child Mode mask
        // (Swap/KaPosts/Broadcasts forced off), and baking that mask into the persisted
        // per-account overlay would leave those tabs hidden even after Child Mode is turned
        // back off. The overlay must only ever record the user's own dock choices.
        var hidden: [String] = []
        if hidePortfolioTab { hidden.append(AppTab.portfolio.rawValue) }
        if hideColdStorageTab { hidden.append(AppTab.coldStorage.rawValue) }
        if hideSwapTab { hidden.append(AppTab.swap.rawValue) }
        if hideKaPostsTab { hidden.append(AppTab.kaposts.rawValue) }
        if hideBroadcasts { hidden.append(AppTab.broadcasts.rawValue) }
        if hideAppsTab { hidden.append(AppTab.apps.rawValue) }
        if hideMoreItem { hidden.append(AppTab.more.rawValue) }
        return DockOverlay(tabOrder: tabOrder, hiddenTabs: hidden)
    }

    /// Writes the dock fields of `settings` to the active account's overlay blob. Called from
    /// both save paths so the per-account copy can never drift from what the user sees.
    static func persistDockOverlay(_ settings: AppSettings) {
        guard let address = activeDockAddress() else { return }
        if let data = try? JSONEncoder().encode(settings.dockOverlay()) {
            UserDefaults.standard.set(data, forKey: dockOverlayKey(for: address))
        }
    }
    // MARK: - Chats Privacy (fresh-address payment pools) - PER ACCOUNT

    /// Chats Privacy is PER ACCOUNT, like the dock: each wallet on this install decides
    /// independently whether its 1:1 payments consume fresh pool addresses and whether it keeps
    /// offering/requesting pools (see ChatService+PaymentPools). A single boolean doesn't need
    /// the dock's overlay-blob machinery - it's stored as one per-wallet-address UserDefaults
    /// key (same scoping pattern as the spending-address and payment-pool stores), default ON
    /// (missing key == enabled). Not part of the AppSettings Codable blob at all, so there is
    /// no decode/migration concern and an account switch takes effect immediately: every gate
    /// reads the CURRENT wallet's value live at decision time.
    ///
    /// The toggle only gates the send side (pool consumption, addr_pool/addr_pool_request
    /// emission, serving inbound requests). Inbound payment_notice handling and watching
    /// already-offered reserved addresses stay active regardless - payments to previously
    /// shared addresses must keep rendering and being noticed.
    static func chatsPrivacyKey(for address: String) -> String { "kachat_chats_privacy_\(address)" }

    static func chatsPrivacyEnabled(for address: String) -> Bool {
        (UserDefaults.standard.object(forKey: chatsPrivacyKey(for: address)) as? Bool) ?? true
    }

    static func setChatsPrivacyEnabled(_ enabled: Bool, for address: String) {
        UserDefaults.standard.set(enabled, forKey: chatsPrivacyKey(for: address))
    }

    /// Convenience for the active account (readable from any context via the same app-group
    /// address `activeDockAddress()` uses). No wallet loaded -> default ON.
    static func chatsPrivacyEnabledForActiveAccount() -> Bool {
        guard let address = activeDockAddress() else { return true }
        return chatsPrivacyEnabled(for: address)
    }

    static func setChatsPrivacyEnabledForActiveAccount(_ enabled: Bool) {
        guard let address = activeDockAddress() else { return }
        setChatsPrivacyEnabled(enabled, for: address)
    }

    /// Load settings from UserDefaults (can be called from any context). Cached - see
    /// `AppSettingsCache`.
    static func load() -> AppSettings {
        if let cached = AppSettingsCache.shared.get() { return cached }
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: "kachat_app_settings"),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            AppSettingsCache.shared.set(.default)
            return .default
        }
        // One-time migration for anyone still pointed at a superseded default indexer - the
        // offline kasia.fyi, or the previous community default kasia.wtf now replaced by KaChat's
        // own indexer (kachat.duckdns.org). Users who set a custom indexer keep it; only the old
        // shipped defaults are moved.
        if settings.indexerURL == legacyDefaultIndexerURL || settings.indexerURL == legacyDefaultIndexerURLKasiaWtf {
            settings.indexerURL = defaultIndexerURL
            save(settings)
        }
        // One-time migration for anyone still pointed at the public K social indexer
        // (mainnet.kaspatalk.net) - KaPosts now runs on KaChat's own indexer. Users who set a
        // custom KaPost indexer URL keep it; only the old shipped default is moved.
        if settings.kaPostIndexerURL == legacyDefaultKaPostIndexerURL {
            settings.kaPostIndexerURL = defaultKaPostIndexerURL
            save(settings)
        }
        // One-time 4.0 dock rules: EVERY existing user gets KaPosts/Broadcasts enabled.
        // The decode fallbacks cover production 3.0 users (their blobs lack these keys), but
        // 4.0 TestFlight builds already wrote hideKaPostsTab = true into saved blobs via the
        // old defaults - this sentinel-guarded pass flips them once. The dock cap then does
        // the right thing: full dock -> KaPosts/Broadcasts cycle behind Chats. ("+More" no
        // longer exists as a dock item, so hideMoreItem isn't touched anymore.)
        let dockRulesKey = "kachat_dock_40_rules_applied"
        if !userDefaults.bool(forKey: dockRulesKey) {
            settings.hideKaPostsTab = false
            settings.hideBroadcasts = false
            userDefaults.set(true, forKey: dockRulesKey)
            save(settings)
        }
        // One-time 4.1 dock rules: Ecosystem replaces Swap's dock slot and takes over holding
        // KaPosts, Broadcasts and the websites list, so every existing user is moved onto the new
        // arrangement rather than only new installs getting it. Their per-tab on/off choices are
        // untouched - only the ORDER is reset, which is what decides who gets a dock slot.
        let ecosystemRulesKey = "kachat_dock_41_ecosystem_applied"
        if !userDefaults.bool(forKey: ecosystemRulesKey) {
            settings.tabOrder = AppTab.defaultOrder.map(\.rawValue)
            settings.hideEcosystemTab = false
            // Turned on for everyone too: it was off by default while it had to win a dock slot,
            // and its home is now a tile in Ecosystem that costs nothing to keep.
            settings.hideAppsTab = false
            userDefaults.set(true, forKey: ecosystemRulesKey)
            save(settings)
        }
        // Per-account dock: the active account's saved arrangement wins over the global blob.
        if let address = activeDockAddress() {
            if let data = userDefaults.data(forKey: dockOverlayKey(for: address)),
               let overlay = try? JSONDecoder().decode(DockOverlay.self, from: data) {
                settings.applyDockOverlay(overlay)
            } else {
                // First load for this account: freeze its inherited dock into its own blob NOW.
                // Without this, an account that never saves settings would keep inheriting the
                // global blob - which a later save on a DIFFERENT account overwrites, leaking
                // that account's dock back into this one.
                persistDockOverlay(settings)
            }
        }
        AppSettingsCache.shared.set(settings)
        return settings
    }

    /// Symmetric write path for services that don't hold a `SettingsViewModel` reference (e.g.
    /// SwapService persisting the swap disclaimer flag) - same storage key/notification as
    /// `SettingsViewModel.saveSettings()`, just callable without an instance.
    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: "kachat_app_settings")
        persistDockOverlay(settings)
        // Keep the app-group mirror current on this path too - the Diagnostics page's Verbose
        // API Logging toggle saves through here, and the NSE reads that flag from the mirror.
        SharedDataManager.syncNotificationSettingsForExtension(settings)
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings

    private let userDefaults = UserDefaults.standard
    private let settingsKey = "kachat_app_settings"

    init() {
        self.settings = AppSettings.load()
        // Account switches post .settingsDidChange with a nil object (see WalletManager) so the
        // new account's dock overlay takes effect immediately. Saves post WITH the settings
        // object - skipped here, this instance already holds those values.
        NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.object == nil else { return }
            Task { @MainActor [weak self] in
                self?.settings = AppSettings.load()
            }
        }
    }

    /// Load settings (MainActor convenience)
    static func loadSettings() -> AppSettings {
        return AppSettings.load()
    }

    func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: settingsKey)
        AppSettings.persistDockOverlay(settings)
        SharedDataManager.syncNotificationSettingsForExtension(settings)

        // Notify other services of settings changes
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }

    func resetToDefaults() {
        // Child Mode survives a settings reset (Danger Zone account wipe) - its password record
        // lives in the Keychain and outlives UserDefaults, so the flag must not silently drop
        // back to off without the password ever being entered.
        let childModeEnabled = settings.childModeEnabled
        settings = .default
        settings.childModeEnabled = childModeEnabled
        saveSettings()
    }

    // MARK: - Convenience Methods
    var storeMessagesInICloud: Bool {
        get { settings.storeMessagesInICloud }
        set {
            settings.storeMessagesInICloud = newValue
            saveSettings()
        }
    }

    var networkType: NetworkType {
        get { settings.networkType }
        set {
            settings.networkType = newValue
            saveSettings()
        }
    }

    var notificationsEnabled: Bool {
        get { settings.notificationsEnabled }
        set {
            settings.notificationsEnabled = newValue
            saveSettings()
        }
    }

    var backgroundFetchEnabled: Bool {
        get { settings.backgroundFetchEnabled }
        set {
            settings.backgroundFetchEnabled = newValue
            saveSettings()
        }
    }

    var notificationMode: NotificationMode {
        get { settings.notificationMode }
        set {
            settings.notificationMode = newValue
            saveSettings()
        }
    }

    var indexerURL: String {
        get { settings.indexerURL }
        set {
            settings.indexerURL = newValue
            saveSettings()
        }
    }

    var pushIndexerURL: String {
        get { settings.pushIndexerURL }
        set {
            settings.pushIndexerURL = newValue
            saveSettings()
        }
    }

    /// Read-only: the KNS endpoint is fixed to the network's default (see `AppSettings`).
    var knsBaseURL: String { settings.knsBaseURL }

    var kaspaRestAPIURL: String {
        get { settings.kaspaRestAPIURL }
        set {
            settings.kaspaRestAPIURL = newValue
            saveSettings()
        }
    }

    var kaspaExplorer: KaspaExplorer {
        get { settings.kaspaExplorer }
        set {
            settings.kaspaExplorer = newValue
            saveSettings()
        }
    }

    var liveUpdatesEnabled: Bool {
        get { settings.liveUpdatesEnabled }
        set {
            settings.liveUpdatesEnabled = newValue
            saveSettings()
        }
    }

    /// Validates and applies a new trusted-node address (empty = automatic discovery instead of a
    /// pinned node). Returns a user-facing error message and leaves `settings` untouched if
    /// `value` is non-empty but not a valid endpoint; returns `nil` on success. Shared by
    /// `ConnectionSettingsView` and the Welcome Guide's node-connection step so both stay in sync
    /// with `NodePoolService`, not just `AppSettings`.
    @discardableResult
    func applyTrustedNode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Endpoint(url: trimmed) != nil else {
            return "Enter as host:port or grpcs://host"
        }
        guard trimmed != settings.trustedNodeAddress else { return nil }
        settings.trustedNodeAddress = trimmed
        saveSettings()
        Task {
            await NodePoolService.shared.setTrustedNodeAddress(trimmed)
        }
        return nil
    }

    /// Sets or clears the standard `AppleLanguages` preferred-language override. The main app
    /// itself doesn't need this (it picks up a language change immediately via
    /// `.environment(\.locale, ...)` in `KaChatApp.swift`, no restart) - this is for the pieces
    /// that run as their own separate OS process and can't observe that in-memory environment
    /// override at all: the Notification Service Extension, Share Extension, and the OS's own
    /// Bundle-driven resolution on the next cold launch of any of them. Shared by the Settings >
    /// Language picker and the Welcome Guide's language step.
    func applyLanguagePreference(_ language: AppLanguage) {
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
