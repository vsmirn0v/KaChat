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
        /// Retryable: a dropped connection, a timeout, a server that was briefly down. The link
        /// stays live and says so.
        case failed
        /// Terminal for this post and this reader: the pair is not served, the post is too long,
        /// the text was already in the reader's language. Retrying cannot change the answer, so
        /// the affordance says what happened instead of inviting a pointless second tap.
        case unavailable(String)
    }

    /// Per-post translation state, keyed by `translationKey(for:)`.
    @Published private(set) var states: [String: State] = [:]
    /// Posts the user has flipped back to the original text. Kept separately from `states` so
    /// toggling back and forth never re-runs the translation.
    @Published private(set) var showingOriginal: Set<String> = []

    /// What the configured service can actually translate (`GET /translate/languages`).
    ///
    /// `nil` means "we do not know yet", either because the answer has not arrived or because the
    /// deployment does not implement the endpoint. Both fall back to offering the link anyway,
    /// which is the behaviour `TRANSLATION_SERVICE.md` specifies.
    @Published private(set) var supportedLanguages: SupportedLanguages?

    struct SupportedLanguages: Equatable {
        let source: Set<String>
        let target: Set<String>
    }

    /// The service URL `supportedLanguages` was fetched from. Held so a change in Settings >
    /// Connection Settings re-asks the new deployment rather than trusting the old one's answer.
    private var supportedLanguagesURL: String?
    private var isRefreshingSupportedLanguages = false

    private init() {}

    // MARK: - Detection

    /// Confidence floor for `NLLanguageRecognizer` on Latin-script text of `minimumLetters` or
    /// more. Short social-media text is genuinely hard to identify, and a wrong guess is worse
    /// than no offer: it puts a "Translate from Portuguese" link under a perfectly readable
    /// English post.
    private static let minimumConfidence = 0.55
    /// The floor for Latin-script text SHORTER than `minimumLetters`. A short post has to be
    /// nearly certain, but certainty is common: measured, "bom dia" scores 0.79 and "sehr gut"
    /// 1.00, while "hola" scores 0.56 and "gm" 0.28. This used to be a hard letter floor instead,
    /// which rejected "đang rất hóng" - eleven letters, Vietnamese at 1.00 - and "danke schön"
    /// (ten, 1.00) before the recognizer ever ran, so a short reply in another language showed no
    /// Translate link at all.
    private static let shortTextConfidence = 0.75
    /// Where the long-text floor takes over from the short-text one.
    private static let minimumLetters = 12
    /// Below this the recognizer is not worth running: emoji-only and "gm" posts fall out here.
    private static let minimumLettersToDetect = 4

    /// Stable per-post key. On-chain posts key by their txid so a translation survives the feed
    /// being re-sorted or re-paged; local session posts fall back to their UUID.
    static func translationKey(for remoteId: String?, localId: UUID) -> String {
        remoteId ?? localId.uuidString
    }

    /// Detection results cached by post text.
    ///
    /// `canOffer` is read from the cell's body, so it runs for every visible post on every render
    /// pass while scrolling. `NLLanguageRecognizer` over a 25k-character post is nowhere near
    /// cheap enough for that. Keyed by content, like the cell's own linkify cache, and boxed
    /// because NSCache holds objects.
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
        let letterCount = stripped.filter(\.isLetter).count
        guard letterCount >= minimumLettersToDetect else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(stripped)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
            .filter { $0.key != .undetermined }
            .sorted { $0.value > $1.value }
        guard let best = hypotheses.first else { return nil }

        // Script beats probability. `NLLanguageRecognizer` weights Latin words heavily, so a post
        // in a non-Latin script that also carries brand names, tickers or a "GM" can come back as
        // a Latin-script language outright - measured: Arabic text with one Latin word identifies
        // as Urdu-in-Arabic-script, and worse, some mixed posts identify as Swedish. When the text
        // is overwhelmingly written in one script, a language that is not written in that script
        // is simply the wrong answer, whatever probability was attached to it, so the best
        // hypothesis that IS written in that script wins instead.
        //
        // No confidence floor and no length floor on that branch. The floors exist to stop a
        // coin-flip between two Latin-script languages putting "Translate from Portuguese" under
        // readable English; neither is needed to know that Cyrillic text is not Swedish - the
        // script already said so - and five letters of kana identify as Japanese at 1.00.
        if let script = dominantScript(of: stripped), script != Self.latinScript {
            if scriptCode(of: best.key) != script,
               let sameScript = hypotheses.first(where: { scriptCode(of: $0.key) == script }) {
                return Locale.Language(identifier: sameScript.key.rawValue)
            }
            return Locale.Language(identifier: best.key.rawValue)
        }

        // Latin script: the floor scales with length. Short text is where the coin-flips live,
        // so it has to be nearly certain; from `minimumLetters` up the usual floor applies.
        let floor = letterCount >= minimumLetters ? minimumConfidence : shortTextConfidence
        guard best.value >= floor else { return nil }
        return Locale.Language(identifier: best.key.rawValue)
    }

    private static let latinScript = "Latn"

    /// The ISO 15924 script a language is normally written in, from CLDR's own likely-subtags data
    /// ("ru" -> "ru-Cyrl-RU"), so there is no hand-maintained language-to-script table to fall out
    /// of date.
    private static func scriptCode(of language: NLLanguage) -> String? {
        Locale.Language(identifier: language.rawValue)
            .maximalIdentifier
            .split(separator: "-")
            .dropFirst()
            .first
            .map(String.init)
    }

    /// The script at least half the letters are written in, or nil when the text is genuinely
    /// mixed. Deliberately coarse: it only has to separate "this is Cyrillic/Arabic/Han/..." from
    /// "this is Latin", which is the call the recognizer gets wrong.
    private static func dominantScript(of text: String) -> String? {
        var counts: [String: Int] = [:]
        var total = 0
        for character in text where character.isLetter {
            guard let scalar = character.unicodeScalars.first else { continue }
            counts[scriptName(for: scalar.value), default: 0] += 1
            total += 1
        }
        guard total > 0, let winner = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(winner.value) / Double(total) >= 0.5 ? winner.key : nil
    }

    /// Unicode block to script code. Only the blocks that matter for the languages a translation
    /// service serves; everything else counts as Latin, which is the conservative answer because
    /// the Latin branch is the one that keeps the confidence floor.
    private static func scriptName(for value: UInt32) -> String {
        switch value {
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return "Grek"
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return "Cyrl"
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: return "Hebr"
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "Arab"
        case 0x0900...0x097F: return "Deva"
        case 0x0E00...0x0E7F: return "Thai"
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF: return "Hang"
        case 0x3040...0x30FF, 0x31F0...0x31FF: return "Jpan"
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return "Hani"
        default: return latinScript
        }
    }

    private static func strippedForDetection(_ text: String) -> String {
        var result = text
        for pattern in [#"https?://\S+"#, #"@[A-Za-z0-9._-]+"#] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    // MARK: - The reader's language

    /// The language the reader actually reads KaChat in, as the bare subtag the server expects
    /// ("en", not "en-GB"; "zh" for "zh-Hans").
    ///
    /// This is Settings > Language when it has been set, and only falls back to the device locale
    /// for `.system`. It deliberately does NOT read `Locale.current`, which is the DEVICE's
    /// language: the in-app override is applied through `.environment(\.locale, ...)` at the app
    /// root (see `AppLanguage.locale`) and through `AppleLanguages` for the next cold launch, so
    /// `Locale.current` does not reflect it in-process. Reading it here is what made a reader who
    /// picked Vietnamese on an English phone get English posts with no Translate link at all
    /// (source == target, so nothing was offered) and Vietnamese posts translated INTO English.
    static var readerLanguageCode: String? {
        if let chosen = AppSettings.load().language.appleLanguageCode {
            return Locale.Language(identifier: chosen).languageCode?.identifier
        }
        return Locale.current.language.languageCode?.identifier
    }

    /// The locale to name languages in, so "Translated from Vietnamese" is written in the
    /// language the reader chose rather than the one the phone is set to.
    private static var readerLocale: Locale {
        AppSettings.load().language.locale ?? .current
    }

    /// Localized name of a language, for "Translated from X".
    static func displayName(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "another language" }
        return readerLocale.localizedString(forLanguageCode: code) ?? code
    }

    /// Should this post offer a Translate link? Only when the language is identifiable, is not
    /// already the reader's own, and the service can actually serve the pair.
    ///
    /// No OS gate any more: with the work on the server, iOS 16 and 17 get this too. They used to
    /// see no affordance at all, because Apple's framework starts at 18.
    func canOffer(for text: String) -> Bool {
        guard let target = Self.readerLanguageCode,
              let detected = Self.detectedLanguage(of: text),
              let source = detected.languageCode?.identifier,
              source != target else { return false }
        guard let supported = supportedLanguages,
              supportedLanguagesURL == Self.currentServiceURL else { return true }
        return supported.source.contains(source) && supported.target.contains(target)
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
        guard let target = Self.readerLanguageCode else {
            states[key] = .failed
            return
        }
        do {
            let result = try await Self.requestTranslation(text: text, postId: postId, target: target)
            // The server returns the text unchanged when it decides the post was already in the
            // reader's language - our detection is a guess and is sometimes wrong. Showing the
            // same text back under a "Translated from" line would look broken, and inviting a
            // retry is worse: the second tap gets the same answer.
            guard !result.untranslated, !result.text.isEmpty else {
                states[key] = .unavailable("Already in your language")
                return
            }
            let sourceName = result.source.map { Self.displayName(of: Locale.Language(identifier: $0)) }
            states[key] = .translated(
                text: result.text,
                sourceName: sourceName ?? "another language"
            )
        } catch let error as TranslationError {
            AppLog.log("%@", "[Translate] Failed: \(error.errorDescription ?? "")")
            states[key] = error.isTerminal ? .unavailable(error.readerMessage) : .failed
        } catch {
            AppLog.log("%@", "[Translate] Failed: \(error.localizedDescription)")
            states[key] = .failed
        }
    }

    // MARK: - Supported languages

    /// Asks the service what it can translate, so a reader whose language the deployment does not
    /// serve is never offered a link that can only fail. Cheap, cached by the server, and asked
    /// once per launch plus whenever the service URL changes.
    func refreshSupportedLanguages() {
        let url = Self.currentServiceURL
        if supportedLanguages != nil, supportedLanguagesURL == url { return }
        if isRefreshingSupportedLanguages { return }
        isRefreshingSupportedLanguages = true
        Task { [weak self] in
            let fetched = await Self.requestSupportedLanguages()
            guard let self else { return }
            self.isRefreshingSupportedLanguages = false
            guard let fetched else { return }
            self.supportedLanguagesURL = url
            self.supportedLanguages = fetched
        }
    }

    private static func requestSupportedLanguages() async -> SupportedLanguages? {
        guard var components = translationServiceComponents() else { return nil }
        components.path += "/translate/languages"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(LanguagesResponse.self, from: data) else {
            return nil
        }
        let source = Set(decoded.source.map { $0.lowercased() })
        let target = Set(decoded.target.map { $0.lowercased() })
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return SupportedLanguages(source: source, target: target)
    }

    // MARK: - Wire

    private struct TranslationResult {
        let text: String
        let source: String?
        let untranslated: Bool
    }

    /// The configured service URL, trimmed, with the shipped default standing in for a blank one.
    private static var currentServiceURL: String {
        let raw = AppSettings.load().translationServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? AppSettings.defaultTranslationServiceURL : raw
    }

    private static func translationServiceComponents() -> URLComponents? {
        var components = URLComponents(string: currentServiceURL)
        // A trailing slash on a custom URL would otherwise produce "//translate".
        if components?.path.hasSuffix("/") == true { components?.path.removeLast() }
        return components
    }

    /// One post per call today. The endpoint takes an array because the shape should not have to
    /// change when a "translate everything on screen" action wants a batch.
    private static func requestTranslation(text: String, postId: String?, target: String) async throws -> TranslationResult {
        guard var components = translationServiceComponents() else { throw TranslationError.badURL }
        components.path += "/translate"
        guard let url = components.url else { throw TranslationError.badURL }

        var post: [String: String] = ["text": text]
        if let postId, !postId.isEmpty { post["id"] = postId }
        let body: [String: Any] = ["target": target, "posts": [post]]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Deliberately no identity header of any kind - see the note on this type.
        // Encoded (and, below, decoded) off the main actor: this service is `@MainActor`, and
        // a post's worth of JSON is small but the feed is scrolling while it happens.
        request.httpBody = try await Task.detached(priority: .userInitiated) {
            try JSONSerialization.data(withJSONObject: body)
        }.value
        // Generous, because the FIRST request for a language pair can make the server load that
        // pair's model. Everyone after that is answered from its cache in well under a second, so
        // the only reader who ever waits this long is the one who asked first. A 20s cap here
        // turned that one reader's request into a failure banner.
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.badResponse }
        guard http.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(APIError.self, from: data)
            throw TranslationError.server(message: decoded?.error ?? "HTTP \(http.statusCode)", code: decoded?.code)
        }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(TranslateResponse.self, from: data)
        }.value
        guard let entry = decoded.translations.first else { throw TranslationError.badResponse }
        if let error = entry.error { throw TranslationError.server(message: error, code: entry.code) }
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
            let code: String?
        }
    }

    private struct LanguagesResponse: Decodable {
        let source: [String]
        let target: [String]
    }

    private struct APIError: Decodable {
        let error: String?
        let code: String?
    }

    private enum TranslationError: LocalizedError {
        case badURL
        case badResponse
        case server(message: String, code: String?)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid translation service URL"
            case .badResponse: return "Unexpected response from the translation service"
            case .server(let message, _): return message
            }
        }

        /// Codes whose answer will not change on a second tap. Everything else - a timeout, a
        /// rate limit, a server restart - keeps the retry link.
        var isTerminal: Bool {
            guard case .server(_, let code) = self, let code else { return false }
            return ["UNSUPPORTED_PAIR", "TEXT_TOO_LONG", "INVALID_POST_ID", "MISSING_PARAMETER"].contains(code)
        }

        /// What the reader is told under the post. Short, and never a raw server string for the
        /// one case where we have better words than the server does.
        var readerMessage: String {
            guard case .server(let message, let code) = self else { return "Translation unavailable" }
            return code == "UNSUPPORTED_PAIR" ? "Not available in your language" : message
        }
    }
}
