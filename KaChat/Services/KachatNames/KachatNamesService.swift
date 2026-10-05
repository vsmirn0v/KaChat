import Foundation
import P256K
import Security

/// `.kachat` names: the app side of the transaction core (`KachatNames.*`, pure and checked against
/// the kachat-domains vectors). This service adds what needs the app: the testnet gate, loading and
/// verifying the manifest, the node's DAG point, the wallet's and the registry's live UTXOs,
/// Schnorr signing with the wallet key (P256K, SIGHASH_ALL over the version-1 sighash), the
/// protowire conversion with the Toccata fields, and submission through `NodePoolService`.
///
/// Transactions are testnet-10 only: every entry point refuses unless `AppSettings.networkType ==
/// .testnet`, and the manifest itself must be for testnet-10. The mainnet registry stays off until
/// the contracts are audited - but the .kachat UI and identity are on for every network (see
/// `isEnabled` / `isLaunched`).
///
/// Phase 4a: no UI calls this yet. A screen will: `loadManifest()`, read the records it needs (the
/// indexer's `/names/...` endpoints), confirm them with `liveRegistryUtxo`, `environment(...)`,
/// build with `builder()`, show the plan's fee, then `signAndSubmit`.
@MainActor
final class KachatNamesService: ObservableObject {
    static let shared = KachatNamesService()

    @Published private(set) var manifest: KachatNames.Manifest?
    /// Where the manifest came from: "bundle" or the indexer URL.
    @Published private(set) var manifestSource: String?
    /// The manifest describes the previous registry (v1): names wait for the v2 genesis manifest.
    /// The screens show "Setting up" instead of an error.
    @Published private(set) var registryUpgrading = false

    /// Why the bundled manifest was refused. The bundle can't change while the app runs, so it
    /// is not read and verified again on every call (until `resetManifest`).
    private var bundleFailure: Error?

    enum ServiceError: LocalizedError {
        case testnetOnly
        case wrongAddressNetwork
        case noManifest(String)
        case dryRunManifest
        case wrongNodeNetwork(String)
        case keyMismatch
        case notOnChain(String)
        case badProfile(String)
        case submitMismatch(expected: String, got: String)
        /// the manifest is for registry v1; this app builds for v2 and waits for its genesis
        case registryUpgrading

        var errorDescription: String? {
            switch self {
            case .registryUpgrading:
                return AppLocalization.string("The .kachat registry on Testnet is being upgraded. Names open here again once the new registry is live.")
            case .testnetOnly: return ".kachat names run on Testnet only for now"
            case .wrongAddressNetwork: return AppLocalization.string("This address is on a different network than the app.")
            case .noManifest(let why): return "No .kachat registry manifest: \(why)"
            case .dryRunManifest: return "The .kachat manifest is from a dry run; that registry does not exist"
            case .wrongNodeNetwork(let n): return "The node is on \(n), not testnet-10"
            case .keyMismatch: return "The signing key is not the key the transaction was built for"
            case .notOnChain(let what): return "\(what) is not on chain (or not with the registry covenant id)"
            case .badProfile(let why): return "Profile: \(why)"
            case .submitMismatch(let e, let g): return "The node accepted \(g), expected \(e)"
            }
        }
    }

    private init() {}

    // MARK: - Gate

    /// The only network names may run on until an audit.
    /// The .kachat UI and identity - on every network since 2026-10-04: mainnet shows the same
    /// screens as testnet (and people by their .kachat name, not KNS), in a "Coming soon" state
    /// until its registry launches. Every UI change lands on both networks. The KNS branches this
    /// guards are kept, unreachable, as a switch-back.
    nonisolated static var isEnabled: Bool { true }
    /// Whether this network has a live registry the app reads and transacts with (lookups,
    /// listings, registrations, resolving typed names): testnet-10 only for now.
    nonisolated static var isLaunched: Bool { AppSettings.load().networkType == .testnet }
    /// Address profiles (`kchat:1:profile:`) work on every network: a profile is a plain
    /// self-send from the chatting address, with no registry behind it, so mainnet can save and
    /// read them before its registry launches. Only the primary name needs the registry.
    nonisolated static var profilesEnabled: Bool { isEnabled }

    /// Whether `error` means the registry is being upgraded (a v1 manifest), not a failure.
    nonisolated static func isRegistryUpgrading(_ error: Error) -> Bool {
        if case ServiceError.registryUpgrading = error { return true }
        return (error as? KachatNames.Failure)?.isOutdatedRegistry == true
    }

    func requireTestnet() throws {
        guard Self.isEnabled else { throw ServiceError.testnetOnly }
    }

    // MARK: - Manifest

    /// The verified registry manifest: `kachat-names-testnet-10.json` from the app bundle when it
    /// ships one, else the indexer's `GET /names/manifest`. Cached once verified.
    func loadManifest(allowDryRun: Bool = false) async throws -> KachatNames.Manifest {
        try requireTestnet()
        if let m = manifest, allowDryRun || !m.isDryRun {
            return m
        }
        if let bundleFailure { throw bundleFailure }
        let (data, source) = try await manifestData()
        let m: KachatNames.Manifest
        do {
            m = try KachatNames.Manifest.decode(data)
            try m.verify()
        } catch {
            // A registry v1 manifest (the bundled one until the v2 genesis) is expected, not an
            // error: say "being upgraded", once, and stop re-reading the bundle.
            let refused: Error = Self.isRegistryUpgrading(error) ? ServiceError.registryUpgrading : error
            if Self.isRegistryUpgrading(error) {
                if !registryUpgrading { AppLog.log("[KachatNames] the %@ manifest is registry v1; .kachat waits for the v2 genesis manifest", source) }
                registryUpgrading = true
            }
            if source == "bundle" { bundleFailure = refused }
            throw refused
        }
        if m.isDryRun && !allowDryRun {
            throw ServiceError.dryRunManifest
        }
        registryUpgrading = false
        manifest = m
        manifestSource = source
        return m
    }

    /// Forget the cached manifest (network switch, indexer change).
    func resetManifest() {
        manifest = nil
        manifestSource = nil
        bundleFailure = nil
        registryUpgrading = false
    }

    private func manifestData() async throws -> (Data, String) {
        if let url = Bundle.main.url(forResource: KachatNames.Manifest.bundleResource, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return (data, "bundle")
        }
        let base = AppSettings.load().indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw ServiceError.noManifest("none in the app and no indexer is configured for Testnet")
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + "/names/manifest") else {
            throw ServiceError.noManifest("bad indexer URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.noManifest("the indexer answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return (data, url.absoluteString)
    }

    /// The pure builders over the verified manifest.
    func builder() async throws -> KachatNames.Builder {
        try KachatNames.Builder(manifest: try await loadManifest())
    }

    // MARK: - Environment

    /// The signer's x-only key for a wallet private key.
    nonisolated static func xonlyKey(privateKey: Data) throws -> Data {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(key.xonly.bytes)
    }

    /// Where the next transaction is judged: the virtual's DAA score and past median time from a
    /// testnet-10 node, the wall clock, the signer's key.
    func environment(privateKey: Data, feerate: Double = KachatNames.minFeerate) async throws -> KachatNames.Env {
        try requireTestnet()
        let dag = try await NodePoolService.shared.currentDagPoint()
        guard dag.networkName.hasSuffix("testnet-10") else {
            throw ServiceError.wrongNodeNetwork(dag.networkName)
        }
        return KachatNames.Env(
            me: try Self.xonlyKey(privateKey: privateKey),
            blockDaa: dag.virtualDaaScore,
            blockTimeMs: dag.pastMedianTimeMs,
            wallMs: Int64(Date().timeIntervalSince1970 * 1000),
            feerate: max(feerate, KachatNames.minFeerate)
        )
    }

    // MARK: - UTXOs

    /// The wallet's spendable funding UTXOs for the builders: the signer's own Schnorr P2PK
    /// outputs only, mature, and never one carrying a covenant id (spending that would drag a
    /// covenant into the transaction and change its storage mass).
    nonisolated static func fundingUtxos(_ utxos: [UTXO], me: Data, virtualDaaScore: UInt64) -> [KachatNames.Utxo] {
        let mine = KachatNames.Codec.p2pkScript(me)
        return KasiaTransactionBuilder.spendableForBuild(utxos, virtualDaaScore: virtualDaaScore).compactMap { u in
            guard u.covenantId == nil, u.scriptPublicKey == mine else { return nil }
            return try? convert(u)
        }
    }

    nonisolated static func convert(_ u: UTXO) throws -> KachatNames.Utxo {
        KachatNames.Utxo(
            outpoint: KachatNames.Outpoint(txid: try KachatNames.unhex32(u.outpoint.transactionId), index: u.outpoint.index),
            entry: KachatNames.UtxoEntry(
                amount: u.amount,
                script: u.scriptPublicKey,
                blockDaaScore: u.blockDaaScore,
                isCoinbase: u.isCoinbase,
                covenantId: try u.covenantId.map { try KachatNames.unhex32($0) }
            )
        )
    }

    /// The `kaspatest:` P2SH address of a P2SH script (`OP_BLAKE2B <hash> OP_EQUAL`).
    nonisolated static func p2shAddress(script: Data) -> String? {
        let b = [UInt8](script)
        guard b.count == 35, b[0] == 0xaa, b[1] == 0x20, b[34] == 0x87 else { return nil }
        return KaspaAddress(hrp: "kaspatest", type: .scriptHash, payload: Data(b[2..<34])).address
    }

    /// The live UTXO at `outpoint` holding `script` (a gap, name or offer), read from a node with
    /// its covenant id. A registry record from the indexer is trusted only once this confirms it:
    /// the P2SH address commits to the whole state, and the covenant id to the registry lineage.
    func liveUtxo(script: Data, outpoint: KachatNames.Outpoint) async throws -> KachatNames.Utxo {
        try requireTestnet()
        guard let address = Self.p2shAddress(script: script) else { throw ServiceError.notOnChain("a non-P2SH script") }
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        let txidHex = KachatNames.hex(outpoint.txid)
        guard let u = utxos.first(where: { $0.outpoint.transactionId.lowercased() == txidHex && $0.outpoint.index == outpoint.index }) else {
            throw ServiceError.notOnChain("\(txidHex):\(outpoint.index)")
        }
        let live = try Self.convert(u)
        guard live.entry.script == script else { throw ServiceError.notOnChain("\(txidHex):\(outpoint.index) with that state") }
        return live
    }

    /// `liveUtxo` for a gap or name, which must also carry the registry covenant id.
    func liveRegistryUtxo(script: Data, outpoint: KachatNames.Outpoint) async throws -> KachatNames.Utxo {
        let m = try await loadManifest()
        let u = try await liveUtxo(script: script, outpoint: outpoint)
        guard u.entry.covenantId == m.registryCovenantId else { throw ServiceError.notOnChain("a registry UTXO") }
        return u
    }

    // MARK: - Salts

    /// A fresh 32-byte commit salt. Keep it (with the name) until the registration: without it
    /// the commit cannot be registered.
    nonisolated static func newSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KachatNames.Failure("no randomness for the salt")
        }
        return Data(bytes)
    }

    // MARK: - Signing

    /// Signs every input that needs it with the wallet key: BIP-340 Schnorr over the version-1
    /// SIGHASH_ALL sighash, each signature verified before it is used. `plan` must have been
    /// built for this key (`Env.me`).
    nonisolated static func sign(_ plan: KachatNames.Plan, privateKey: Data, me: Data) throws -> KachatNames.Tx {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        let xonly = Data(key.xonly.bytes)
        guard xonly == me else { throw ServiceError.keyMismatch }
        let verifier = P256K.Schnorr.XonlyKey(dataRepresentation: xonly)
        return try plan.signed { sighash in
            var message = [UInt8](sighash)
            let signature = try key.signature(message: &message, auxiliaryRand: nil)
            let ok = verifier.isValid(signature, for: &message)
            for i in message.indices { message[i] = 0 }
            guard ok else { throw KachatNames.Failure("signature did not verify") }
            return Data(signature.bytes)
        }
    }

    // MARK: - Protowire

    /// The SubmitTransaction form of a version-1 transaction: `computeBudget` on every input
    /// (`sigOpCount` must stay 0 for version 1), covenant bindings on outputs, the storage mass.
    nonisolated static func rpcTransaction(_ tx: KachatNames.Tx) -> Protowire_RpcTransaction {
        var r = Protowire_RpcTransaction()
        r.version = UInt32(tx.version)
        r.inputs = tx.inputs.map { i in
            var input = Protowire_RpcTransactionInput()
            var op = Protowire_RpcOutpoint()
            op.transactionID = KachatNames.hex(i.outpoint.txid)
            op.index = i.outpoint.index
            input.previousOutpoint = op
            input.signatureScript = KachatNames.hex(i.signatureScript)
            input.sequence = i.sequence
            input.sigOpCount = 0
            input.computeBudget = UInt32(i.computeBudget)
            return input
        }
        r.outputs = tx.outputs.map { o in
            var output = Protowire_RpcTransactionOutput()
            output.amount = o.value
            var spk = Protowire_RpcScriptPublicKey()
            spk.version = UInt32(o.scriptVersion)
            spk.scriptPublicKey = KachatNames.hex(o.script)
            output.scriptPublicKey = spk
            if let c = o.covenant {
                var binding = Protowire_RpcCovenantBinding()
                binding.authorizingInput = UInt32(c.authorizingInput)
                binding.covenantID = KachatNames.hex(c.covenantId)
                output.covenant = binding
            }
            return output
        }
        r.lockTime = tx.lockTime
        r.subnetworkID = KachatNames.hex(tx.subnetworkId)
        r.gas = tx.gas
        r.payload = KachatNames.hex(tx.payload)
        r.storageMass = tx.storageMass
        return r
    }

    // MARK: - Submit

    /// Submits a signed version-1 transaction; returns its id. Register and renew carry the
    /// price (35-8,000 TKAS) as fee on purpose - there is no high-fee guard on this path.
    @discardableResult
    func submit(_ tx: KachatNames.Tx) async throws -> String {
        try requireTestnet()
        let expected = tx.idHex
        let (txId, endpoint) = try await NodePoolService.shared.submitRpcTransaction(Self.rpcTransaction(tx))
        AppLog.log("[KachatNames] submitted %@ via %@", txId, endpoint)
        guard txId.lowercased() == expected else { throw ServiceError.submitMismatch(expected: expected, got: txId) }
        return txId
    }

    /// Sign with the wallet key and submit.
    @discardableResult
    func signAndSubmit(_ plan: KachatNames.Plan, privateKey: Data, env: KachatNames.Env) async throws -> String {
        try requireTestnet()
        let tx = try Self.sign(plan, privateKey: privateKey, me: env.me)
        return try await submit(tx)
    }

    // MARK: - Profile record

    /// The address profile record (KACHAT_NAMES.md section 7): a self-transfer with payload
    /// `kchat:1:profile:<json>`, built and signed by the existing version-0 payload builder.
    /// `json` is the whole profile (records replace, never patch), a JSON object of at most 2 KB.
    func buildProfileRecord(address: String, privateKey: Data, utxos: [UTXO], json: Data) throws -> KaspaRpcTransaction {
        guard Self.profilesEnabled else { throw ServiceError.testnetOnly }
        // The record is written from the wallet's address on the network the app runs on.
        guard NetworkType(address: address) == AppSettings.load().networkType else { throw ServiceError.wrongAddressNetwork }
        guard json.count <= KachatNames.Codec.maxProfileJSONBytes else { throw ServiceError.badProfile("over 2 KB") }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ServiceError.badProfile("not a JSON object")
        }
        guard (object["v"] as? NSNumber)?.intValue == 1 else { throw ServiceError.badProfile("\"v\" must be 1") }
        let payload = KachatNames.Codec.profilePayload(json: json)
        let plain = utxos.filter { $0.covenantId == nil }
        return try KasiaTransactionBuilder.buildPayloadSelfSendTx(
            from: address, senderPrivateKey: privateKey, utxos: plain, payload: payload
        )
    }

    /// Build, sign and submit the profile record; returns its id.
    @discardableResult
    func submitProfileRecord(address: String, privateKey: Data, utxos: [UTXO], json: Data) async throws -> String {
        let tx = try buildProfileRecord(address: address, privateKey: privateKey, utxos: utxos, json: json)
        return try await NodePoolService.shared.submitTransaction(tx).txId
    }
}
