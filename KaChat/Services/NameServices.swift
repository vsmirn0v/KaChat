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

    /// Whether the app can read this service yet.
    var isLive: Bool { self != .kachat }

    /// The tab Your Domains opens on: `.kachat` once it is live, KNS until then.
    static var defaultTab: NameServiceTLD { NameServiceTLD.kachat.isLive ? .kachat : .kas }
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

    // MARK: - .k (dotk)

    private struct DotkOwnerResponse: Decodable {
        let names: [String]
    }

    private func fetchDotk(address: String, network: NetworkType) async -> [OwnedServiceName]? {
        let base = network == .mainnet ? "https://api.dotk.name/v1" : "https://api-tn10.dotk.name/v1"
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
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
        guard let url = URL(string: "https://kaspaname.com/v1/addresses/\(identifier)/names") else { return nil }
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
