import Foundation

/// The `.kachat` registry for the screens: lookups, an owner's names, listings, lapsed names,
/// offers, history and identities, from one of two sources -
///
/// - **the names indexer** (KACHAT_NAMES_INDEXER.md Part D) at `AppSettings.indexerURL`, used when
///   that field is set and `GET /names/status` answers 200 for this manifest's registry id;
/// - **the chain walker** otherwise: the registry's live UTXO set (gaps and names, plus the offers
///   this device made) kept from the manifest's genesis gap forward. A refresh asks a node which
///   tracked UTXOs are still unspent, finds each spent one's spending transaction through the
///   Kaspa REST API (`GET /addresses/{p2sh}/full-transactions`), decodes the spend like the
///   indexer does (B3), verifies every new state against its output script and moves on. Cached
///   per network in Application Support.
///
/// Records from either source are only read here; every action re-reads its UTXOs from a node
/// (`KachatNamesService.liveRegistryUtxo`) before it builds anything. Testnet-10 only.
@MainActor
final class KachatNamesRegistry: ObservableObject {
    static let shared = KachatNamesRegistry()

    enum Source: Equatable {
        case indexer(String)
        case chain

        var isIndexer: Bool { if case .indexer = self { return true } else { return false } }
    }

    /// The address profile this wallet last wrote (the walker cannot read anyone's profile).
    struct OwnProfile: Codable, Equatable {
        var address: String
        var profile: KachatNames.Profile
        var txId: String
        var at: Int64
    }

    @Published private(set) var source: Source?
    @Published private(set) var chainState: KachatNames.RegistryState?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var refreshedAt: Date?
    /// Bumped whenever registry data may have changed, so screens reload.
    @Published private(set) var revision = 0

    private var cacheNetwork: String?
    private var ownProfiles: [String: OwnProfile] = [:]

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }

    // MARK: - Setup

    /// The verified manifest, with the source picked and the walker's cache loaded.
    @discardableResult
    func prepare(forceSourceCheck: Bool = false) async throws -> KachatNames.Manifest {
        let m = try await service.loadManifest()
        if source == nil || forceSourceCheck {
            source = await chooseSource(m)
        }
        if source == .chain, chainState == nil || cacheNetwork != m.network {
            chainState = Self.loadCache(m) ?? .atGenesis(m)
            cacheNetwork = m.network
        }
        return m
    }

    /// Forget everything in memory (network switch, logout).
    func reset() {
        source = nil
        chainState = nil
        cacheNetwork = nil
        ownProfiles = [:]
        lastError = nil
        refreshedAt = nil
        revision += 1
    }

    var graceMs: Int64 { service.manifest?.params.graceMs ?? 864_000_000 }

    private func chooseSource(_ m: KachatNames.Manifest) async -> Source {
        guard let base = Self.indexerBase() else { return .chain }
        guard let status: KachatNames.IndexerAPI.StatusJSON = try? await Self.get(base, "/names/status"),
              status.registryCovenantId?.lowercased() == KachatNames.hex(m.registryCovenantId) else {
            return .chain
        }
        return .indexer(base)
    }

    static func indexerBase() -> String? {
        let raw = AppSettings.load().indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Refresh

    /// Walks the chain forward (no indexer) or just marks fresh data (indexer). Safe to call often.
    func refresh(forceSourceCheck: Bool = false) async {
        guard KachatNamesService.isEnabled else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let m = try await prepare(forceSourceCheck: forceSourceCheck)
            if source == .chain {
                try await walk(m)
            }
            lastError = nil
            refreshedAt = Date()
        } catch {
            lastError = error.localizedDescription
            AppLog.log("[KachatNames] registry refresh failed: %@", error.localizedDescription)
        }
        revision += 1
    }

    /// `refresh()` unless the last one is younger than `maxAge` seconds (lookups from typed names).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh()
    }

    private func walk(_ m: KachatNames.Manifest) async throws {
        var state = chainState ?? .atGenesis(m)
        let registryId = KachatNames.hex(m.registryCovenantId)
        let report = try await state.walk(
            manifest: m,
            address: { KachatNamesService.p2shAddress(script: $0) },
            live: { addresses in
                var out = Set<String>()
                var start = 0
                while start < addresses.count {
                    let chunk = Array(addresses[start..<min(start + 50, addresses.count)])
                    for u in try await NodePoolService.shared.getUtxosByAddresses(chunk) {
                        // A node reports the covenant id; the REST fallback cannot (nil). A UTXO
                        // carrying another id is not the registry's.
                        if let c = u.covenantId, !c.isEmpty, c.lowercased() != registryId { continue }
                        out.insert("\(u.outpoint.transactionId.lowercased()):\(u.outpoint.index)")
                    }
                    start += 50
                }
                return out
            },
            transactions: { address in try await Self.restTransactions(address: address) }
        )
        state.verifiedAt = KachatNames.nowMs()
        if !report.applied.isEmpty {
            AppLog.log("[KachatNames] walked %d registry transaction(s) in %d round(s)", report.applied.count, report.rounds)
        }
        if !report.unresolved.isEmpty {
            AppLog.log("[KachatNames] %d spent registry UTXO(s) wait for the REST API to index their spend", report.unresolved.count)
        }
        chainState = state
        Self.saveCache(state)
    }

    /// Accepted transactions touching `address`, newest first (kaspa-rest-server).
    static func restTransactions(address: String) async throws -> [KachatNames.TxView] {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/addresses/\(address)/full-transactions?limit=50&offset=0&resolve_previous_outpoints=no") else {
            throw KachatNames.Failure("bad Kaspa REST API URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw KachatNames.Failure("the Kaspa REST API answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(address)")
        }
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return try list.compactMap { try KachatNames.TxView.fromREST($0) }
    }

    /// Whether the REST API has seen `txId` accepted.
    static func isAccepted(txId: String) async -> Bool {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (j["is_accepted"] as? Bool) == true
    }

    /// After a submit: wait (up to ~2 minutes) for the transaction to be accepted, then refresh.
    func refreshAfter(txId: String) {
        Task { @MainActor in
            for attempt in 0..<40 {
                try? await Task.sleep(nanoseconds: UInt64(attempt < 5 ? 2 : 3) * 1_000_000_000)
                if await Self.isAccepted(txId: txId) { break }
            }
            await refresh()
        }
    }

    // MARK: - Reads

    func lookup(_ raw: String) async throws -> KachatNames.Lookup {
        try await prepare()
        let name = KachatNames.Codec.normalize(raw)
        try KachatNames.Codec.validate(name)
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.NameJSON = try await Self.get(base, "/names/\(name)")
            if let info = j.info(keyOf: Self.keyOf) { return .registered(info) }
            return .free(name: name, gap: j.gap?.info)
        default:
            guard let st = chainState else { throw KachatNames.Failure("the registry is not loaded") }
            if let n = st.name(name) { return .registered(KachatNames.RegistryState.info(n)) }
            return .free(name: name, gap: st.gap(containing: KachatNames.Codec.key(name)).map(KachatNames.RegistryState.info))
        }
    }

    /// The names an owner holds, oldest first; `includeInactive` adds grace and lapsed ones.
    func names(owner: Data, includeInactive: Bool) async throws -> [KachatNames.NameInfo] {
        try await prepare()
        let all: [KachatNames.NameInfo]
        switch source {
        case .indexer(let base):
            guard let address = Self.address(of: owner) else { return [] }
            let j: KachatNames.IndexerAPI.NamesJSON = try await Self.get(base, "/names/by-owner/\(address)?includeInactive=\(includeInactive)")
            all = j.names.compactMap { $0.info(keyOf: Self.keyOf) }
        default:
            let ownerHex = KachatNames.hex(owner)
            all = (chainState?.names ?? []).filter { $0.owner == ownerHex }.map(KachatNames.RegistryState.info)
        }
        let grace = graceMs
        return all
            .filter { includeInactive || $0.status(graceMs: grace) == .active }
            .sorted { ($0.registeredAt ?? .max, $0.name) < ($1.registeredAt ?? .max, $1.name) }
    }

    /// Active names listed for sale, most recently changed first.
    func listings() async throws -> [KachatNames.NameInfo] {
        try await prepare()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.ListingsJSON = try await Self.get(base, "/market/listings?sort=recent")
            return j.listings.compactMap { $0.info(keyOf: Self.keyOf) }
        default:
            let grace = graceMs
            return (chainState?.names ?? []).map(KachatNames.RegistryState.info)
                .filter { $0.isListed && $0.status(graceMs: grace) == .active }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        }
    }

    /// Lapsed names anyone may reclaim, oldest expiry first.
    func lapsed() async throws -> [KachatNames.NameInfo] {
        try await prepare()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.NamesJSON = try await Self.get(base, "/names/expiring")
            return j.names.compactMap { $0.info(keyOf: Self.keyOf) }
        default:
            let grace = graceMs
            return (chainState?.names ?? []).map(KachatNames.RegistryState.info)
                .filter { $0.status(graceMs: grace) == .lapsed }
                .sorted { $0.expiresAt < $1.expiresAt }
        }
    }

    /// Open offers on a name. Without an indexer only the offers this device made are known.
    func offers(for name: String) async throws -> [KachatNames.OfferInfo] {
        try await prepare()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.OffersJSON = try await Self.get(base, "/names/\(name)/offers")
            return j.offers.compactMap { $0.info(name: name, keyOf: Self.keyOf) }.sorted { $0.amount > $1.amount }
        default:
            let key = KachatNames.hex(KachatNames.Codec.key(name))
            return (chainState?.offers ?? []).filter { $0.key == key }.map(KachatNames.RegistryState.info).sorted { $0.amount > $1.amount }
        }
    }

    /// The offers `buyer` made that are still open.
    func myOffers(buyer: Data) async throws -> [KachatNames.OfferInfo] {
        try await prepare()
        switch source {
        case .indexer(let base):
            guard let address = Self.address(of: buyer) else { return [] }
            let j: KachatNames.IndexerAPI.OffersJSON = try await Self.get(base, "/offers/by-buyer/\(address)")
            return j.offers.compactMap { $0.info(name: nil, keyOf: Self.keyOf) }
        default:
            let me = KachatNames.hex(buyer)
            return (chainState?.offers ?? []).filter { $0.buyer == me }.map(KachatNames.RegistryState.info)
        }
    }

    /// A name's history, newest first. The walker knows every registry transition it walked.
    func history(name: String) async throws -> [KachatNames.Event] {
        try await prepare()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.EventsJSON = try await Self.get(base, "/names/\(name)/history")
            return j.events.map(\.event)
        default:
            return (chainState?.events ?? []).filter { $0.name == name }.reversed()
        }
    }

    /// Recent registry activity, newest first.
    func activity() async throws -> [KachatNames.Event] {
        try await prepare()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.EventsJSON = try await Self.get(base, "/market/activity")
            return j.events.map(\.event)
        default:
            return Array((chainState?.events ?? []).reversed().prefix(200))
        }
    }

    /// The two gaps around a registered name (what release and reclaim spend).
    func exitGaps(for n: KachatNames.NameInfo) async throws -> (below: KachatNames.GapInfo, above: KachatNames.GapInfo) {
        try await prepare()
        switch source {
        case .indexer(let base):
            guard let down = KachatNames.step(n.key, by: -1), let up = KachatNames.step(n.key, by: 1) else {
                throw KachatNames.Failure("no gaps around \(n.name)")
            }
            let below: KachatNames.IndexerAPI.GapJSON = try await Self.get(base, "/names/gap/\(KachatNames.hex(down))")
            let above: KachatNames.IndexerAPI.GapJSON = try await Self.get(base, "/names/gap/\(KachatNames.hex(up))")
            guard let b = below.info, let a = above.info, b.hi == n.key, a.lo == n.key else {
                throw KachatNames.Failure("the indexer has no gaps around \(n.name)")
            }
            return (b, a)
        default:
            guard let nb = chainState?.neighbours(of: n.key) else { throw KachatNames.Failure("no gaps around \(n.name) yet - refresh") }
            return (KachatNames.RegistryState.info(nb.below), KachatNames.RegistryState.info(nb.above))
        }
    }

    // MARK: - Identity and profiles

    /// The label and profile of an address (KACHAT_NAMES.md section 7). Without an indexer the
    /// label comes from the walked names, and the profile is known only for this wallet's own
    /// address (the record it last wrote).
    func identity(address: String) async throws -> KachatNames.Identity {
        try await prepare()
        let address = address.lowercased()
        switch source {
        case .indexer(let base):
            let j: KachatNames.IndexerAPI.IdentityJSON = try await Self.get(base, "/identity/\(address)")
            return j.identity
        default:
            guard let key = Self.keyOf(address) else { return KachatNames.Identity(address: address, label: nil, names: [], profile: nil) }
            let owned = try await names(owner: key, includeInactive: false)
            let profile = ownProfile(for: address)?.profile
            let label = KachatNames.label(owned: owned, primaryName: profile?.primaryName, graceMs: graceMs)
            return KachatNames.Identity(address: address, label: label, names: owned.map(\.name), profile: profile)
        }
    }

    /// The profile record this device last wrote for `address`.
    func ownProfile(for address: String) -> OwnProfile? {
        let address = address.lowercased()
        if let p = ownProfiles[address] { return p }
        guard let data = Self.readFile(Self.profileFile(address)), let p = try? JSONDecoder().decode(OwnProfile.self, from: data) else { return nil }
        ownProfiles[address] = p
        return p
    }

    func noteOwnProfile(_ profile: KachatNames.Profile, address: String, txId: String) {
        let record = OwnProfile(address: address.lowercased(), profile: profile.sanitized(), txId: txId, at: KachatNames.nowMs())
        ownProfiles[record.address] = record
        if let data = try? JSONEncoder().encode(record) { Self.writeFile(Self.profileFile(record.address), data) }
        revision += 1
    }

    /// An offer this wallet just created: tracked by the walker from now on.
    func trackOffer(_ offer: KachatNames.OfferInfo) {
        guard var st = chainState else { return }
        st.trackOffer(offer, at: KachatNames.nowMs())
        chainState = st
        Self.saveCache(st)
        revision += 1
    }

    // MARK: - Addresses

    nonisolated static func address(of xonly: Data) -> String? {
        guard xonly.count == 32 else { return nil }
        return KaspaAddress(hrp: "kaspatest", type: .pubKey, payload: xonly).address
    }

    /// The x-only key of a `kaspatest:` Schnorr address.
    nonisolated static func keyOf(_ address: String) -> Data? {
        guard let a = KaspaAddress(address: address.lowercased()), a.hrp == "kaspatest", a.type == .pubKey, a.payload.count == 32 else { return nil }
        return a.payload
    }

    /// `kaspatest:qr...xyz4`.
    nonisolated static func shortAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(14))...\(address.suffix(6))"
    }

    // MARK: - HTTP

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func get<T: Decodable>(_ base: String, _ path: String) async throws -> T {
        guard let url = URL(string: base + path) else { throw KachatNames.Failure("bad indexer URL") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw KachatNames.Failure("not found") }
            throw KachatNames.Failure("the names indexer answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cache files (Application Support/KachatNames/<network>/)

    private static func directory(network: String = KachatNames.Manifest.supportedNetwork) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("KachatNames", isDirectory: true).appendingPathComponent(network, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func readFile(_ name: String) -> Data? {
        guard let dir = directory() else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func writeFile(_ name: String, _ data: Data) {
        guard let dir = directory() else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func walletSuffix(_ address: String) -> String {
        KeychainService.walletHashSuffix(address.lowercased())
    }

    private static func profileFile(_ address: String) -> String { "profile-\(walletSuffix(address)).json" }

    private static func loadCache(_ m: KachatNames.Manifest) -> KachatNames.RegistryState? {
        guard let data = readFile("registry.json"),
              let st = try? JSONDecoder().decode(KachatNames.RegistryState.self, from: data),
              st.matches(m), (try? st.checkInvariants()) != nil else { return nil }
        return st
    }

    private static func saveCache(_ st: KachatNames.RegistryState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(st) { writeFile("registry.json", data) }
    }
}
