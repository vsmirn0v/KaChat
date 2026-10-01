import Foundation

/// The Kaspa name services besides KNS, which `KNSService` covers (`.kas`):
///
/// - `.k` - dotk (dotk.name). Read API `https://api.dotk.name/v1`, reference SDK `@dotk/sdk`.
///   `GET /addresses/{kaspa address}` lists every live name an owner holds.
/// - `.kaspa` - Kaspa Names (kaspaname.com), covenant-backed names on L1. Read API
///   `https://kaspaname.com/v1`, reference SDK `@kronsdk/kaspa-names`.
///   `GET /addresses/{owner identifier}/names` lists an owner's names, where the identifier is
///   the 64-hex x-only public key inside a P2PK address - not the `kaspa:` string itself.
/// - `.kachat` - KaChat's own names. Not live yet; listed so the app already has its place.
///
/// Read-only, like both SDKs: nothing here needs a wallet key. Listing an owner's names needs no
/// name normalization (the services return their own canonical forms); resolving a name a person
/// TYPED does, and each service's rule is adjudication-critical - port it against that SDK's
/// published vectors before adding forward resolution here.
enum NameServiceTLD: String, CaseIterable, Identifiable {
    // Declaration order is the tab order: KaChat's own names first.
    case kachat
    case kas
    case k
    case kaspa

    var id: String { rawValue }

    /// ".kas", ".k" ... - the tab label and the display suffix.
    var suffix: String { ".\(rawValue)" }

    /// Who runs it, for empty states and links.
    var serviceName: String {
        switch self {
        case .kas: return "KNS"
        case .k: return "dotk"
        case .kaspa: return "Kaspa Names"
        case .kachat: return "KaChat Names"
        }
    }

    /// Where a person gets one of these names today.
    var websiteURL: URL? {
        switch self {
        case .kas: return URL(string: "https://app.knsdomains.org")
        case .k: return URL(string: "https://dotk.name")
        case .kaspa: return URL(string: "https://kaspaname.com")
        case .kachat: return nil
        }
    }

    /// The read API this app calls for the service, shown in Connection Settings > Domains.
    /// nil for `.kas` (KNS has its own setting there) and `.kachat` (not live).
    func apiBaseURL(for network: NetworkType) -> String? {
        switch self {
        case .k: return network == .mainnet ? "https://api.dotk.name/v1" : "https://api-tn10.dotk.name/v1"
        case .kaspa: return network == .mainnet ? "https://kaspaname.com/v1" : nil
        case .kas, .kachat: return nil
        }
    }

    /// The site's name as people know it, for "Get a .kas domain at knsdomains.org".
    var websiteName: String? {
        switch self {
        case .kas: return "knsdomains.org"
        case .k: return "dotk.name"
        case .kaspa: return "kaspaname.com"
        case .kachat: return nil
        }
    }

    /// Whether the app can read this service yet.
    var isLive: Bool { self != .kachat }

    /// The tab Your Domains opens on: `.kachat` once it is live, KNS until then.
    static var defaultTab: NameServiceTLD { NameServiceTLD.kachat.isLive ? .kachat : .kas }
}

/// Name normalization for the outside name services - adjudication-critical: a normalizer that
/// disagrees with a service's own on one byte can resolve a typed name to the wrong owner.
/// Each is a port of that service's SDK, checked against its published vectors (all of
/// ~/kns-sdk/vectors/normalization.json and ~/dotk-sdk/src/generated/*/vectors.json `normalize`
/// pass). Re-check them whenever an SDK's vectors change.
enum NameNormalization {
    /// `.k` (dotk, `@dotk/sdk` names.ts): trim Unicode White_Space, lowercase A-Z only, drop one
    /// trailing ".k"; valid when 1...32 bytes of a-z, 0-9 and hyphen with no hyphen at either end.
    static func dotkNormalize(_ input: String) -> String {
        var scalars = Array(input.unicodeScalars)
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var lowered = String.UnicodeScalarView()
        for scalar in scalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                lowered.append(Unicode.Scalar(scalar.value + 0x20)!)
            } else {
                lowered.append(scalar)
            }
        }
        let s = String(lowered)
        return s.hasSuffix(".k") ? String(s.dropLast(2)) : s
    }

    static func dotkInvalidReason(_ name: String) -> String? {
        let allowed = name.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0.value == 0x2D
        }
        if !allowed { return "allowed characters: a-z, 0-9 and hyphen" }
        let bytes = name.utf8.count
        if bytes == 0 || bytes > 32 { return "name must be 1..=32 bytes on-chain" }
        if name.hasPrefix("-") || name.hasSuffix("-") { return "name cannot start or end with a hyphen" }
        return nil
    }

    /// The canonical `.k` name for typed input, or nil when it is not one.
    static func dotkCanonical(_ input: String) -> String? {
        let n = dotkNormalize(input)
        return dotkInvalidReason(n) == nil ? n : nil
    }

    /// `.kaspa` (Kaspa Names, `@kronsdk/kaspa-names` normalize.ts): NFKC, printable ASCII only,
    /// lowercase, drop one trailing ".kaspa"; valid when 1...32 of a-z, 0-9 and hyphen with no
    /// hyphen at either end.
    static func kaspaNamesCanonical(_ input: String) -> String? {
        let nfkc = input.precomposedStringWithCompatibilityMapping
        for unit in nfkc.utf16 where unit > 0x7E || unit < 0x21 { return nil }
        var s = nfkc.lowercased()
        if s.hasSuffix(".kaspa") { s = String(s.dropLast(6)) }
        guard (1...32).contains(s.utf16.count) else { return nil }
        guard s.unicodeScalars.allSatisfy({
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0.value == 0x2D
        }) else { return nil }
        guard !s.hasPrefix("-"), !s.hasSuffix("-") else { return nil }
        return s
    }
}

/// What a typed name points to on one service.
struct NameResolution: Identifiable, Equatable {
    let tld: NameServiceTLD
    /// The canonical name with its suffix, e.g. "bob.k".
    let display: String
    /// Where it points; nil when the name is not registered there (or has no address to pay).
    let address: String?
    /// The service could not be asked (network or server failure), so "not registered" is unknown.
    let failed: Bool

    var id: String { tld.rawValue }
}

extension NameServiceTLD {
    /// The order a bare name ("bob") is tried in: KaChat's own .kachat always first, then KNS,
    /// dotk and Kaspa Names. The first that resolves is the answer; the rest are offered as
    /// "Other domains".
    static let resolutionOrder: [NameServiceTLD] = [.kachat, .kas, .k, .kaspa]

    /// Splits typed input into its label and the ending the person typed, if any. Longest endings
    /// first, so "bob.kaspa" is not read as "bob.kas" + "pa".
    static func splitTypedName(_ input: String) -> (label: String, tld: NameServiceTLD?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for tld in [NameServiceTLD.kachat, .kaspa, .kas, .k] where lowered.hasSuffix(tld.suffix) {
            return (String(trimmed.dropLast(tld.suffix.count)), tld)
        }
        return (trimmed, nil)
    }
}

/// One name an address owns on a service other than KNS.
struct OwnedServiceName: Identifiable, Equatable {
    /// The bare canonical name, without the suffix.
    let name: String
    /// The display form, e.g. "shawn.kaspa".
    let display: String
    let tld: NameServiceTLD
    /// A `.kaspa` name still inside its settling window (~1 h after registration), when an
    /// earlier hidden commit could still outrank it - shown, but marked as not final yet.
    let isProvisional: Bool

    var id: String { display }
}

@MainActor
final class NameServicesClient: ObservableObject {
    static let shared = NameServicesClient()

    /// Names per service, for the address last refreshed. Empty until the first answer.
    @Published private(set) var owned: [NameServiceTLD: [OwnedServiceName]] = [:]
    /// Services whose last lookup is still running.
    @Published private(set) var loading: Set<NameServiceTLD> = []
    /// Services whose last lookup failed (network, server) - the tab says so instead of
    /// claiming there are no names.
    @Published private(set) var failed: Set<NameServiceTLD> = []
    /// Whose names `owned` holds; a different address clears it first.
    private(set) var ownerAddress: String?

    private init() {}

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Every name `address` owns on .k and .kaspa. A lookup that fails keeps what the service
    /// last answered and marks it failed.
    func refresh(for address: String) async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return }
        if ownerAddress != address {
            ownerAddress = address
            owned = [:]
            failed = []
        }
        let network = AppSettings.load().networkType
        async let dotk: [OwnedServiceName]? = fetchDotk(address: address, network: network)
        async let kaspaNames: [OwnedServiceName]? = fetchKaspaNames(address: address, network: network)
        loading.formUnion([.k, .kaspa])
        let (k, kaspa) = await (dotk, kaspaNames)
        guard ownerAddress == address else { return }
        apply(k, for: .k)
        apply(kaspa, for: .kaspa)
        loading.subtract([.k, .kaspa])
    }

    /// How many names the address owns across these services (for the "Your Domains" count).
    var totalOwned: Int {
        owned.values.reduce(0) { $0 + $1.count }
    }

    private func apply(_ names: [OwnedServiceName]?, for tld: NameServiceTLD) {
        if let names {
            owned[tld] = names
            failed.remove(tld)
        } else {
            failed.insert(tld)
        }
    }

    // MARK: - Any address (account discovery)

    /// Names `address` owns on .k and .kaspa, for scanning many addresses - it leaves `owned`
    /// (Your Domains' address) alone. A failed lookup counts as no names.
    func ownedNames(of address: String) async -> [OwnedServiceName] {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return [] }
        let network = AppSettings.load().networkType
        async let dotk = fetchDotk(address: address, network: network)
        async let kaspaNames = fetchKaspaNames(address: address, network: network)
        let (k, kaspa) = await (dotk, kaspaNames)
        return (k ?? []) + (kaspa ?? [])
    }

    /// `ownedNames(of:)` for many addresses, a few lookups at a time rather than one burst of
    /// two requests per address against services that rate-limit.
    func ownedNames(of addresses: [String], concurrency: Int = 6) async -> [String: [OwnedServiceName]] {
        var result: [String: [OwnedServiceName]] = [:]
        var start = 0
        while start < addresses.count {
            let slice = addresses[start..<min(start + concurrency, addresses.count)]
            await withTaskGroup(of: (String, [OwnedServiceName]).self) { group in
                for address in slice {
                    group.addTask { (address, await self.ownedNames(of: address)) }
                }
                for await (address, names) in group where !names.isEmpty {
                    result[address] = names
                }
            }
            start += concurrency
        }
        return result
    }

    /// Whether `address` owns a name on any service KaChat reads - .kas, .k and .kaspa today.
    /// Account discovery asks this so an address that holds only a name, and no KAS, is still
    /// found. .kachat joins here once its registry is live (`NameServiceTLD.isLive`).
    func ownsAnyName(_ address: String) async -> Bool {
        async let kas = KNSService.shared.ownsAnyDomain(address)
        async let others = ownedNames(of: address)
        let (hasKas, otherNames) = await (kas, others)
        return hasKas || !otherNames.isEmpty
    }

    // MARK: - .k (dotk)

    private struct DotkOwnerResponse: Decodable {
        let names: [String]
    }

    private func fetchDotk(address: String, network: NetworkType) async -> [OwnedServiceName]? {
        guard let base = NameServiceTLD.k.apiBaseURL(for: network),
              let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/addresses/\(encoded)") else { return nil }
        guard let response: DotkOwnerResponse = await getJSON(url) else { return nil }
        return response.names
            .map { $0.lowercased() }
            .sorted()
            .map { OwnedServiceName(name: $0, display: "\($0).k", tld: .k, isProvisional: false) }
    }

    // MARK: - .kaspa (Kaspa Names)

    private struct KaspaNamesOwnerResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let display: String?
            let status: String?
            let settled: Bool?
            let isWinner: Bool?
        }
        let names: [Entry]
    }

    private func fetchKaspaNames(address: String, network: NetworkType) async -> [OwnedServiceName]? {
        // Mainnet only: the service publishes no testnet deployment.
        guard network == .mainnet else { return [] }
        // The owner identifier is the x-only key a P2PK (Schnorr) address carries. Any other
        // address kind cannot own a name through this lookup.
        guard let key = KaspaAddress.publicKey(from: address), key.count == 32 else { return [] }
        let identifier = key.map { String(format: "%02x", $0) }.joined()
        guard let base = NameServiceTLD.kaspa.apiBaseURL(for: network),
              let url = URL(string: "\(base)/addresses/\(identifier)/names") else { return nil }
        guard let response: KaspaNamesOwnerResponse = await getJSON(url) else { return nil }
        return response.names
            // A losing lineage is a registration that was outranked: not this owner's name.
            .filter { $0.isWinner != false }
            .map { entry in
                let bare = entry.name.lowercased()
                return OwnedServiceName(
                    name: bare,
                    display: entry.display ?? "\(bare).kaspa",
                    tld: .kaspa,
                    isProvisional: entry.settled == false || entry.status == "pending"
                )
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Forward resolution (typed name -> address)

    /// Whether typed input could be a name on any service (and is not an address): a bare label,
    /// or a label with one of the known endings.
    static func looksLikeName(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.hasPrefix("kaspa:"), !trimmed.hasPrefix("kaspatest:") else { return false }
        let label = NameServiceTLD.splitTypedName(trimmed).label
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !label.isEmpty && label.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// What `input` points to on every live service, in `NameServiceTLD.resolutionOrder`.
    /// A service whose own rules reject the label is left out. `.kachat` is skipped until it is
    /// live. Each service normalizes with its own rule (`NameNormalization`).
    func resolveEverywhere(_ input: String) async -> [NameResolution] {
        let label = NameServiceTLD.splitTypedName(input).label
        guard !label.isEmpty else { return [] }
        let network = AppSettings.load().networkType
        async let kas = resolveKas(label)
        async let dotk = resolveDotk(label, network: network)
        async let kaspaNames = resolveKaspaNames(label, network: network)
        let byTLD: [NameServiceTLD: NameResolution] = Dictionary(
            uniqueKeysWithValues: [await kas, await dotk, await kaspaNames].compactMap { $0 }.map { ($0.tld, $0) }
        )
        return NameServiceTLD.resolutionOrder.compactMap { byTLD[$0] }
    }

    /// The answer a typed name gets: the service the person named, if they typed an ending, else
    /// the first in `resolutionOrder` that resolves.
    static func primary(of results: [NameResolution], typed input: String) -> NameResolution? {
        if let explicit = NameServiceTLD.splitTypedName(input).tld {
            return results.first { $0.tld == explicit && $0.address != nil }
        }
        return results.first { $0.address != nil }
    }

    private func resolveKas(_ label: String) async -> NameResolution? {
        guard let canonical = KNSService.shared.normalizeDomainLabel(label) else { return nil }
        let display = "\(canonical).kas"
        let resolution = await KNSService.shared.resolveDomain(canonical)
        return NameResolution(tld: .kas, display: display, address: resolution?.ownerAddress, failed: false)
    }

    private struct DotkNameResponse: Decodable {
        let address: String?
    }

    private func resolveDotk(_ label: String, network: NetworkType) async -> NameResolution? {
        guard let canonical = NameNormalization.dotkCanonical(label),
              let base = NameServiceTLD.k.apiBaseURL(for: network),
              let url = URL(string: "\(base)/names/\(canonical)") else { return nil }
        let display = "\(canonical).k"
        let outcome: LookupOutcome<DotkNameResponse> = await getJSONOrMissing(url)
        switch outcome {
        case .found(let body): return NameResolution(tld: .k, display: display, address: body.address, failed: false)
        case .missing: return NameResolution(tld: .k, display: display, address: nil, failed: false)
        case .failed: return NameResolution(tld: .k, display: display, address: nil, failed: true)
        }
    }

    private struct KaspaNamesResolveResponse: Decodable {
        let address: String?
    }

    private func resolveKaspaNames(_ label: String, network: NetworkType) async -> NameResolution? {
        guard let canonical = NameNormalization.kaspaNamesCanonical(label),
              let base = NameServiceTLD.kaspa.apiBaseURL(for: network),
              let url = URL(string: "\(base)/resolve/\(canonical)") else { return nil }
        let display = "\(canonical).kaspa"
        let outcome: LookupOutcome<KaspaNamesResolveResponse> = await getJSONOrMissing(url)
        switch outcome {
        case .found(let body): return NameResolution(tld: .kaspa, display: display, address: body.address, failed: false)
        case .missing: return NameResolution(tld: .kaspa, display: display, address: nil, failed: false)
        case .failed: return NameResolution(tld: .kaspa, display: display, address: nil, failed: true)
        }
    }

    private enum LookupOutcome<T> {
        case found(T)
        case missing
        case failed
    }

    /// A 404 is an answer ("not registered"), anything else that is not 2xx is a failure.
    private func getJSONOrMissing<T: Decodable>(_ url: URL) async -> LookupOutcome<T> {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .missing }
            guard (200..<300).contains(http.statusCode) else { return .failed }
            return .found(try JSONDecoder().decode(T.self, from: data))
        } catch {
            AppLog.log("[NameServices] %@ lookup failed: %@", url.host ?? "?", error.localizedDescription)
            return .failed
        }
    }

    // MARK: - HTTP

    /// Decoded JSON, or nil for any failure (network, non-2xx, unexpected body).
    private func getJSON<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                AppLog.log("[NameServices] %@ answered %d", url.host ?? "?", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.log("[NameServices] %@ failed: %@", url.host ?? "?", error.localizedDescription)
            return nil
        }
    }
}
