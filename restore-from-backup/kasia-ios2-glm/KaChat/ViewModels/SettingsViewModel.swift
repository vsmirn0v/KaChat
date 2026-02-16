import Foundation
import Combine

/// Extension to load settings from any context (not MainActor-isolated)
extension AppSettings {
    /// Load settings from UserDefaults (can be called from any context)
    static func load() -> AppSettings {
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: "kachat_app_settings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
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

    var liveUpdatesEnabled: Bool {
        get { settings.liveUpdatesEnabled }
        set {
            settings.liveUpdatesEnabled = newValue
            saveSettings()
        }
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
