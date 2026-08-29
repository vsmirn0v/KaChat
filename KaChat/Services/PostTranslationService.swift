import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// On-device translation for KaPosts, X-style: a post written in another language offers a
/// "Translate post" link, tapping it swaps the text in place, and the link becomes
/// "Translated from Spanish - Show original".
///
/// Everything runs through Apple's Translation framework, which translates ON DEVICE against a
/// downloaded language pack. No post text is ever sent to a server, which matters here more than
/// in most apps: KaPosts content is public, but WHICH posts a given user chose to read closely is
/// not, and a cloud translator would leak exactly that.
///
/// The framework only vends a `TranslationSession` through the SwiftUI `.translationTask`
/// modifier, so this service cannot translate on its own. It holds the queue and the results; one
/// `PostTranslationHost` in the KaPosts view hierarchy owns the session and drains the queue (see
/// that view). The host is deliberately singular - a session per cell would mean hundreds of them.
///
/// Requires iOS 18. On 16/17 `isSupported` is false and no affordance is ever shown, rather than
/// falling back to iOS 17.4's system translate SHEET: that is a different interaction (a modal
/// overlay, not text swapped in place) and offering it under the same link would be a worse lie
/// than offering nothing.
@MainActor
final class PostTranslationService: ObservableObject {
    static let shared = PostTranslationService()

    /// A translation the host has yet to perform.
    struct PendingRequest: Equatable {
        let key: String
        let text: String
        let sourceLanguage: Locale.Language
    }

    enum State: Equatable {
        case translating
        /// `sourceName` is the localized language name for the "Translated from X" line.
        case translated(text: String, sourceName: String)
        case failed
    }

    /// Per-post translation state, keyed by `translationKey(for:)`.
    @Published private(set) var states: [String: State] = [:]
    /// Posts the user has flipped back to the original text. Kept separately from `states` so
    /// toggling back and forth never re-runs the translation.
    @Published private(set) var showingOriginal: Set<String> = []

    /// Bumped on every new request; the host watches this rather than `pending`, so two requests
    /// for the same post still re-trigger.
    @Published private(set) var requestToken = 0
    private(set) var pending: PendingRequest?

    private init() {}

    /// False on iOS 16/17 - the whole affordance disappears rather than failing on tap.
    static var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    // MARK: - Detection

    /// Confidence floor for `NLLanguageRecognizer`. Short social-media text is genuinely hard to
    /// identify, and a wrong guess is worse than no offer: it puts a "Translate from Portuguese"
    /// link under a perfectly readable English post.
    private static let minimumConfidence = 0.55
    /// Below this many letters, detection is guesswork. Emoji-only and "gm" posts fall out here.
    private static let minimumLetters = 12

    /// Stable per-post key. On-chain posts key by their txid so a translation survives the feed
    /// being re-sorted or re-paged; local session posts fall back to their UUID.
    static func translationKey(for remoteId: String?, localId: UUID) -> String {
        remoteId ?? localId.uuidString
    }

    /// Detection results cached by post text.
    ///
    /// `canOfferTranslation` is read from the cell's body, so it runs for every visible post on
    /// every render pass while scrolling. `NLLanguageRecognizer` over a 25k-character post is
    /// nowhere near cheap enough for that. Keyed by content, like the cell's own linkify cache,
    /// and boxed because NSCache holds objects.
    private static let detectionCache: NSCache<NSString, DetectionBox> = {
        let cache = NSCache<NSString, DetectionBox>()
        cache.countLimit = 400
        return cache
    }()

    private final class DetectionBox {
        let language: Locale.Language?
        init(_ language: Locale.Language?) { self.language = language }
    }

    /// The post's language, or nil when it can't be identified confidently. Cached - see
    /// `detectionCache`.
    static func detectedLanguage(of text: String) -> Locale.Language? {
        let cacheKey = text as NSString
        if let cached = detectionCache.object(forKey: cacheKey) { return cached.language }
        let detected = computeDetectedLanguage(of: text)
        detectionCache.setObject(DetectionBox(detected), forKey: cacheKey)
        return detected
    }

    /// URLs and @mentions are stripped first: a post that is mostly a link otherwise identifies
    /// as whatever language the URL's letters resemble.
    private static func computeDetectedLanguage(of text: String) -> Locale.Language? {
        let stripped = strippedForDetection(text)
        guard stripped.filter(\.isLetter).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(stripped)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence,
              language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    private static func strippedForDetection(_ text: String) -> String {
        var result = text
        for pattern in [#"https?://\S+"#, #"@[A-Za-z0-9._-]+"#] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    /// Should this post offer a Translate link? Only when translation exists on this OS, the
    /// language is identifiable, and it is not already the reader's own language.
    static func canOfferTranslation(for text: String) -> Bool {
        guard isSupported, let detected = detectedLanguage(of: text) else { return false }
        return detected.languageCode != Locale.current.language.languageCode
    }

    /// Localized name of a language, for "Translated from X".
    static func displayName(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "another language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Requests

    func state(for key: String) -> State? { states[key] }

    func isShowingOriginal(_ key: String) -> Bool { showingOriginal.contains(key) }

    /// The text to render for a post: the translation unless there is none yet, it failed, or the
    /// reader asked for the original back.
    func displayText(for key: String, original: String) -> String {
        guard case .translated(let translated, _)? = states[key], !showingOriginal.contains(key) else {
            return original
        }
        return translated
    }

    /// Queues a translation. Re-tapping after a failure retries, which is the useful behaviour
    /// when the failure was a language pack that had not finished downloading.
    func translate(key: String, text: String) {
        guard Self.isSupported, let source = Self.detectedLanguage(of: text) else { return }
        showingOriginal.remove(key)
        states[key] = .translating
        pending = PendingRequest(key: key, text: text, sourceLanguage: source)
        requestToken &+= 1
    }

    func showOriginal(key: String) { showingOriginal.insert(key) }

    func showTranslation(key: String) { showingOriginal.remove(key) }

    /// Runs the queued request against a session the host has just been handed. Called only from
    /// `PostTranslationHost`.
    @available(iOS 18.0, *)
    func perform(with session: TranslationSession) async {
        guard let request = pending else { return }
        pending = nil
        do {
            let response = try await session.translate(request.text)
            states[request.key] = .translated(
                text: response.targetText,
                sourceName: Self.displayName(of: request.sourceLanguage)
            )
        } catch {
            // Most often an unsupported pair or a language pack the user declined to download.
            AppLog.log("%@", "[Translate] Failed: \(error.localizedDescription)")
            states[request.key] = .failed
        }
    }

    /// Wipes every translation. Called on account switch, so one account's reading history does
    /// not linger on screen under another's feed.
    func reset() {
        states.removeAll()
        showingOriginal.removeAll()
        pending = nil
    }
}

/// Owns the single `TranslationSession` for KaPosts and drains
/// `PostTranslationService.shared`'s queue. Renders nothing.
///
/// A fresh `Configuration` per request is what re-arms `.translationTask`; the source language
/// differs per post anyway, and `target: nil` means "the reader's own language", which is exactly
/// what the affordance promises.
@available(iOS 18.0, *)
struct PostTranslationHost: View {
    @ObservedObject private var service = PostTranslationService.shared
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                await service.perform(with: session)
            }
            .onChange(of: service.requestToken) {
                guard let request = service.pending else { return }
                configuration = TranslationSession.Configuration(
                    source: request.sourceLanguage,
                    target: nil
                )
            }
    }
}
