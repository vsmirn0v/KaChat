import Foundation
import NaturalLanguage
import SwiftUI

/// Translation for KaPosts, X-style: a post written in another language offers a "Translate post"
/// link, tapping it swaps the text in place, and the link becomes "Translated from Spanish - Show
/// original".
///
/// The translation itself happens on the KaChat server (see `TRANSLATION_SERVICE.md`), the way X
/// does it, rather than on the device. On-device translation - Apple's Translation framework here,
/// ML Kit on Android - was private but cost the reader a language-pack download of tens of
/// megabytes before the first translation finished, was unavailable at all on iOS 16 and 17, and
/// re-translated the same post on every device that read it. A KaPost is immutable, so the server
/// translates it once and serves that answer to everyone forever.
///
/// The trade, stated plainly because the on-device design was chosen deliberately to avoid it:
/// post CONTENT is public (it is on the blockDAG), but WHICH posts a reader stopped to translate
/// now reaches the server. The request carries no identity of any kind - no pubkey, no token, no
/// account id - and the server is specified not to log bodies and to warm its cache ahead of
/// demand, so most requests are answered without a translation engine ever seeing them.
///
/// Language IDENTIFICATION stays on the device. Deciding whether to offer the link at all runs for
/// every visible post on every render pass, and asking a server that would be a request per post
/// per scroll. `NLLanguageRecognizer` answers it offline, for free.
@MainActor
final class PostTranslationService: ObservableObject {
    static let shared = PostTranslationService()

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

    private init() {}

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

    /// Should this post offer a Translate link? Only when the language is identifiable and is not
    /// already the reader's own.
    ///
    /// No OS gate any more: with the work on the server, iOS 16 and 17 get this too. They used to
    /// see no affordance at all, because Apple's framework starts at 18.
    static func canOfferTranslation(for text: String) -> Bool {
        guard let detected = detectedLanguage(of: text) else { return false }
        return detected.languageCode != Locale.current.language.languageCode
    }

    /// Localized name of a language, for "Translated from X".
    static func displayName(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "another language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// The reader's language, as the bare subtag the server expects ("en", not "en-GB").
    private static var targetLanguageCode: String? {
        Locale.current.language.languageCode?.identifier
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

    /// Translates a post. Re-tapping after a failure retries, which is the useful behaviour when
    /// the failure was a dropped connection.
    ///
    /// `postId` is the txid where there is one. The server caches by it, so a post someone else
    /// already translated into this language comes back without a translation engine running at
    /// all; a post with no txid (a local session post) is translated but not cached.
    func translate(key: String, text: String, postId: String?) {
        // A second tap while one is in flight must not start a second request.
        if case .translating? = states[key] { return }
        showingOriginal.remove(key)
        states[key] = .translating
        Task { await perform(key: key, text: text, postId: postId) }
    }

    func showOriginal(key: String) { showingOriginal.insert(key) }

    func showTranslation(key: String) { showingOriginal.remove(key) }

    /// Wipes every translation. Called on account switch, so one account's reading history does
    /// not linger on screen under another's feed.
    func reset() {
        states.removeAll()
        showingOriginal.removeAll()
    }

    private func perform(key: String, text: String, postId: String?) async {
        guard let target = Self.targetLanguageCode else {
            states[key] = .failed
            return
        }
        do {
            let result = try await Self.requestTranslation(text: text, postId: postId, target: target)
            // The server returns the text unchanged when it decides the post was already in the
            // reader's language - our detection is a guess and is sometimes wrong. Showing the
            // same text back under a "Translated from" line would look broken, so this reads as
            // a failure the reader can dismiss by tapping again.
            guard !result.untranslated, !result.text.isEmpty else {
                states[key] = .failed
                return
            }
            let sourceName = result.source.map { Self.displayName(of: Locale.Language(identifier: $0)) }
            states[key] = .translated(
                text: result.text,
                sourceName: sourceName ?? "another language"
            )
        } catch {
            AppLog.log("%@", "[Translate] Failed: \(error.localizedDescription)")
            states[key] = .failed
        }
    }

    // MARK: - Wire

    private struct TranslationResult {
        let text: String
        let source: String?
        let untranslated: Bool
    }

    /// One post per call today. The endpoint takes an array because the shape should not have to
    /// change when a "translate everything on screen" action wants a batch.
    private static func requestTranslation(text: String, postId: String?, target: String) async throws -> TranslationResult {
        let settings = AppSettings.load()
        let raw = settings.kaPostIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw.isEmpty ? AppSettings.defaultKaPostIndexerURL : raw) else {
            throw TranslationError.badURL
        }
        components.path += "/translate"
        guard let url = components.url else { throw TranslationError.badURL }

        var post: [String: String] = ["text": text]
        if let postId, !postId.isEmpty { post["id"] = postId }
        let body: [String: Any] = ["target": target, "posts": [post]]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Deliberately no identity header of any kind - see the note on this type.
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error
            throw TranslationError.server(message ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(TranslateResponse.self, from: data)
        guard let entry = decoded.translations.first else { throw TranslationError.badResponse }
        if let error = entry.error { throw TranslationError.server(error) }
        guard let translated = entry.text else { throw TranslationError.badResponse }
        return TranslationResult(
            text: translated,
            source: entry.source,
            untranslated: entry.untranslated ?? false
        )
    }

    private struct TranslateResponse: Decodable {
        let translations: [Entry]

        struct Entry: Decodable {
            let id: String?
            let source: String?
            let text: String?
            let untranslated: Bool?
            let error: String?
        }
    }

    private struct APIError: Decodable {
        let error: String?
    }

    private enum TranslationError: LocalizedError {
        case badURL
        case badResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid KaPost indexer URL"
            case .badResponse: return "Unexpected response from the translation service"
            case .server(let message): return message
            }
        }
    }
}
