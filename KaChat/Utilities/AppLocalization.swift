import Foundation

/// Resolves strings/locale against the in-app selected `AppSettings.language` (Settings >
/// Customization > Language) rather than the device's system language. `Text(LocalizedStringKey)`
/// already gets this for free via `.environment(\.locale, AppLocalization.locale)`, set once at
/// the root in `KaChatApp.swift` - SwiftUI re-resolves every `Text` against that environment
/// value's matching `.lproj` bundle live, no relaunch needed (mirrors how Kaspium's Flutter
/// `MaterialApp(locale: ...)` re-resolves its whole widget tree the instant its language
/// `StateNotifier` changes - Flutter's `intl`-backed localization is just reactive widget-tree
/// state, unlike `Bundle.main`/`NSLocalizedString`, which resolve once against the *device's*
/// language and don't listen to SwiftUI's environment at all).
///
/// This type exists for the handful of call sites that build strings manually via
/// `NSLocalizedString`/`String(format:)` instead of going through `Text` - those bypass SwiftUI's
/// environment entirely, so left alone they'd keep reflecting the device's system language even
/// after picking a different one in-app. Route them through here instead.
enum AppLocalization {
    /// `string(_:)` is called several times per row in list-heavy views (e.g.
    /// `MessageBubbleView`), so the resolved bundle/locale are cached here instead of
    /// re-decoding `AppSettings` from `UserDefaults` and re-resolving a `Bundle` on every call.
    /// Invalidated on `.settingsDidChange`, which both `AppSettings.save` and
    /// `SettingsViewModel.saveSettings` post whenever the language changes.
    private final class Cache {
        static let shared = Cache()

        private let lock = NSLock()
        private var cachedBundle: Bundle?
        private var cachedLocale: Locale?
        private var observer: NSObjectProtocol?

        private init() {
            observer = NotificationCenter.default.addObserver(
                forName: .settingsDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                self?.invalidate()
            }
        }

        private func invalidate() {
            lock.lock()
            cachedBundle = nil
            cachedLocale = nil
            lock.unlock()
        }

        var bundle: Bundle {
            lock.lock()
            if let cachedBundle { lock.unlock(); return cachedBundle }
            lock.unlock()
            let resolved = Self.resolveBundle()
            lock.lock()
            cachedBundle = resolved
            lock.unlock()
            return resolved
        }

        var locale: Locale {
            lock.lock()
            if let cachedLocale { lock.unlock(); return cachedLocale }
            lock.unlock()
            let resolved = Self.resolveLocale()
            lock.lock()
            cachedLocale = resolved
            lock.unlock()
            return resolved
        }

        private static func resolveBundle() -> Bundle {
            guard let code = AppSettings.load().language.appleLanguageCode,
                  let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return .main
            }
            return bundle
        }

        private static func resolveLocale() -> Locale {
            guard let code = AppSettings.load().language.appleLanguageCode else {
                return .current
            }
            return Locale(identifier: code)
        }
    }

    /// The `.lproj` bundle matching the selected language, or `Bundle.main` for `.system`
    /// (follow the device's own resolution, exactly as plain `NSLocalizedString` would).
    static var bundle: Bundle { Cache.shared.bundle }

    /// For number/date formatting *within* an already-resolved format string (e.g. which
    /// character separates thousands) - matches what `.environment(\.locale, ...)` drives for
    /// SwiftUI's own `Text`.
    static var locale: Locale { Cache.shared.locale }

    /// Drop-in replacement for `NSLocalizedString(key, comment:)` that looks `key` up in the
    /// selected language's bundle instead of `Bundle.main`'s device-driven one.
    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
