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

/// Extension to load settings from any context (not MainActor-isolated)
extension AppSettings {
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
        // One-time migration for anyone who saved settings before the indexer moved from
        // kasia.fyi to kasia.wtf - kasia.fyi never got the group-chat REST endpoints
        // (`/group-messages/...`, `/group-control/...`), which otherwise 404 forever with no
        // clear signal to the user (group catch-up sync just silently never delivers anything).
        if settings.indexerURL == legacyDefaultIndexerURL {
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
        AppSettingsCache.shared.set(settings)
        return settings
    }

    /// Symmetric write path for services that don't hold a `SettingsViewModel` reference (e.g.
    /// SwapService persisting the swap disclaimer flag) - same storage key/notification as
    /// `SettingsViewModel.saveSettings()`, just callable without an instance.
    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: "kachat_app_settings")
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
    }

    /// Load settings (MainActor convenience)
    static func loadSettings() -> AppSettings {
        return AppSettings.load()
    }

    func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: settingsKey)
        SharedDataManager.syncNotificationSettingsForExtension()

        // Notify other services of settings changes
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }

    func resetToDefaults() {
        settings = .default
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

    var knsBaseURL: String {
        get { settings.knsBaseURL }
        set {
            settings.knsBaseURL = newValue
            saveSettings()
        }
    }

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
