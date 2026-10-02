import Foundation
import P256K

extension KachatNames {
    /// A registration in flight: commit -> wait `tCommit` DAA -> register. Kept per wallet in
    /// Application Support (the salt in the Keychain), so it resumes after a relaunch.
    struct PendingRegistration: Codable, Identifiable, Equatable {
        enum Stage: String, Codable {
            /// the commit transaction was built and is being submitted
            case committing
            /// the commit is on chain (or about to be); waiting until it is `tCommit` deep
            case waiting
            /// the registration was submitted
            case registering
            case registered
            /// someone registered the name first; the commit can be cancelled
            case taken
            case failed
            case cancelling
            case cancelled
        }

        /// Names the salt in the Keychain.
        var id: String
        var name: String
        var years: Int64
        /// x-only owner key, hex
        var owner: String
        var commitTxId: String
        /// the commit's P2SH script, hex
        var commitScript: String
        /// the commit UTXO's DAA score once seen
        var commitDaa: UInt64?
        var registerTxId: String?
        var cancelTxId: String?
        var stage: Stage
        var createdAt: Int64
        var updatedAt: Int64
        var lastError: String?

        /// Still shown on the hub.
        var isOpen: Bool { stage != .cancelled }
        /// The driver has work to do.
        var needsDriving: Bool { [.committing, .waiting, .registering, .cancelling].contains(stage) }
    }
}

/// The `.kachat` actions: every operation the screens offer, built with the pure builders over
/// UTXOs re-read from a node, signed with the wallet key and submitted (`KachatNamesService`),
/// plus the registration driver (commit, wait, register - resumable). Testnet-10 only: each entry
/// goes through `KachatNamesService.requireTestnet()`. Every action returns its txid and refreshes
/// the registry once the transaction is accepted.
@MainActor
final class KachatNamesActions: ObservableObject {
    static let shared = KachatNamesActions()

    @Published private(set) var pending: [KachatNames.PendingRegistration] = []
    /// The virtual DAA score the driver last saw (registration progress).
    @Published private(set) var virtualDaa: UInt64?

    private var pendingWallet: String?
    private var driver: Task<Void, Never>?

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }
    private var registry: KachatNamesRegistry { KachatNamesRegistry.shared }

    enum ActionError: LocalizedError {
        case noWallet
        case keyMismatch
        case invalidKey(String)
        case noSalt
        case notRegisterable(String)

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("No testnet wallet is open.")
            case .keyMismatch: return AppLocalization.string("This wallet's key does not match its address.")
            case .invalidKey(let what): return String(format: AppLocalization.string("%@ is not a valid key (not on the secp256k1 curve)."), what)
            case .noSalt: return AppLocalization.string("The secret for this registration is missing on this device.")
            case .notRegisterable(let why): return why
            }
        }
    }

    // MARK: - Wallet

    struct Signer {
        let address: String
        let privateKey: Data
        let me: Data
    }

    /// The current wallet's testnet address, key and x-only key (they must agree).
    func signer() throws -> Signer {
        try service.requireTestnet()
        guard let address = WalletManager.shared.currentWallet?.publicAddress.lowercased(), address.hasPrefix("kaspatest:"),
              let key = WalletManager.shared.getPrivateKey() else { throw ActionError.noWallet }
        let me = try KachatNamesService.xonlyKey(privateKey: key)
        guard KachatNamesRegistry.keyOf(address) == me else { throw ActionError.keyMismatch }
        return Signer(address: address, privateKey: key, me: me)
    }

    /// The current wallet's x-only key, without touching the private key.
    var myKey: Data? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return KachatNamesRegistry.keyOf(address)
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress.lowercased() }

    /// A key a name or an offer will be locked to must be a point on the curve: the contracts
    /// cannot check it, and an invalid owner locks a name until it lapses.
    nonisolated static func validateKey(_ xonly: Data, _ what: String) throws {
        guard xonly.count == 32, xonly != KachatNames.zero32 else { throw ActionError.invalidKey(what) }
        do {
            _ = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02]) + xonly, format: .compressed)
        } catch {
            throw ActionError.invalidKey(what)
        }
    }

    /// `max(100, the REST API's priority fee rate)` in sompi per gram.
    func feerate() async -> Double {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/info/fee-estimate"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = ((j["priorityBucket"] as? [String: Any])?["feerate"] as? NSNumber)?.doubleValue else {
            return KachatNames.minFeerate
        }
        return max(KachatNames.minFeerate, rate)
    }

    /// Builder, environment and the wallet's funding UTXOs for one transaction.
    private func context(_ s: Signer) async throws -> (KachatNames.Builder, KachatNames.Env, [KachatNames.Utxo]) {
        let builder = try await service.builder()
        let env = try await service.environment(privateKey: s.privateKey, feerate: await feerate())
        virtualDaa = env.blockDaa
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let funding = KachatNamesService.fundingUtxos(utxos, me: s.me, virtualDaaScore: env.blockDaa)
        return (builder, env, funding)
    }

    /// Reads the virtual DAA score (for "refundable now" on offers).
    func refreshVirtualDaa() async {
        if let daa = await NodePoolService.shared.currentVirtualDaaScore() { virtualDaa = daa }
    }

    /// What the wallet can spend on names right now (sompi).
    func spendable() async throws -> UInt64 {
        let s = try signer()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let daa = await NodePoolService.shared.currentVirtualDaaScore() ?? 0
        return KachatNamesService.fundingUtxos(utxos, me: s.me, virtualDaaScore: daa).reduce(0) { $0 + $1.entry.amount }
    }

    // MARK: - Live records

    private func liveName(_ n: KachatNames.NameInfo, _ m: KachatNames.Manifest) async throws -> KachatNames.NameRecord {
        let u = try await service.liveRegistryUtxo(script: m.name.script(n.fields.encoded), outpoint: n.outpoint)
        return KachatNames.NameRecord(fields: n.fields, value: u.entry.amount, utxo: u)
    }

    private func liveGap(_ g: KachatNames.GapInfo, _ m: KachatNames.Manifest) async throws -> KachatNames.GapRecord {
        let u = try await service.liveRegistryUtxo(script: m.gap.script(KachatNames.Codec.gapState(lo: g.lo, hi: g.hi)), outpoint: g.outpoint)
        return KachatNames.GapRecord(lo: g.lo, hi: g.hi, value: u.entry.amount, utxo: u)
    }

    private func liveOffer(_ o: KachatNames.OfferInfo, _ m: KachatNames.Manifest) async throws -> KachatNames.OfferRecord {
        let u = try await service.liveUtxo(script: m.offer.script(o.fields.encoded), outpoint: o.outpoint)
        return KachatNames.OfferRecord(fields: o.fields, value: u.entry.amount, utxo: u, name: o.name)
    }

    // MARK: - Operations

    enum Operation {
        case renew(KachatNames.NameInfo, years: Int64)
        case transfer(KachatNames.NameInfo, to: Data)
        /// price 0 delists
        case list(KachatNames.NameInfo, price: UInt64)
        case buy(KachatNames.NameInfo)
        case offer(name: String, amount: UInt64, refundAfterDaa: UInt64, target: KachatNames.NameInfo?)
        case withdraw(KachatNames.OfferInfo)
        case refund(KachatNames.OfferInfo)
        case accept(KachatNames.OfferInfo, name: KachatNames.NameInfo)
        case release(KachatNames.NameInfo)
        case reclaim(KachatNames.NameInfo)
    }

    /// Builds `op` against live UTXOs without submitting anything: the fee and outputs a sheet
    /// shows before the person confirms.
    func plan(_ op: Operation) async throws -> KachatNames.Plan {
        let s = try signer()
        return try await build(op, s).plan
    }

    private func build(_ op: Operation, _ s: Signer) async throws -> (plan: KachatNames.Plan, env: KachatNames.Env) {
        let m = try await registry.prepare()
        let (b, env, wallet) = try await context(s)
        let plan: KachatNames.Plan
        switch op {
        case .renew(let n, let years):
            plan = try b.renew(env: env, wallet: wallet, name: try await liveName(n, m), years: years)
        case .transfer(let n, let to):
            try Self.validateKey(to, AppLocalization.string("The new owner"))
            plan = try b.transfer(env: env, wallet: wallet, name: try await liveName(n, m), newOwner: to)
        case .list(let n, let price):
            if price > 0, n.status(graceMs: m.params.graceMs) != .active {
                throw ActionError.notRegisterable(AppLocalization.string("An expired name can't be listed. Renew it first."))
            }
            plan = try b.list(env: env, wallet: wallet, name: try await liveName(n, m), price: price)
        case .buy(let n):
            try Self.validateKey(env.me, AppLocalization.string("Your key"))
            plan = try b.buy(env: env, wallet: wallet, name: try await liveName(n, m))
        case .offer(let name, let amount, let refundAfter, let target):
            try Self.validateKey(env.me, AppLocalization.string("Your key"))
            _ = target
            plan = try b.offer(env: env, wallet: wallet, name: name, amount: amount, refundAfter: refundAfter)
        case .withdraw(let o):
            plan = try b.withdrawOffer(env: env, offer: try await liveOffer(o, m))
        case .refund(let o):
            plan = try b.refundOffer(env: env, offer: try await liveOffer(o, m))
        case .accept(let o, let n):
            try Self.validateKey(o.buyer, AppLocalization.string("The buyer"))
            plan = try b.acceptOffer(env: env, name: try await liveName(n, m), offer: try await liveOffer(o, m))
        case .release(let n):
            let gaps = try await registry.exitGaps(for: n)
            plan = try b.release(env: env, parts: KachatNames.ExitParts(
                below: try await liveGap(gaps.below, m), name: try await liveName(n, m), above: try await liveGap(gaps.above, m)))
        case .reclaim(let n):
            let gaps = try await registry.exitGaps(for: n)
            plan = try b.reclaim(env: env, parts: KachatNames.ExitParts(
                below: try await liveGap(gaps.below, m), name: try await liveName(n, m), above: try await liveGap(gaps.above, m)))
        }
        return (plan, env)
    }

    /// Builds, signs and submits `op`; returns the txid. The registry refreshes once the
    /// transaction is accepted.
    @discardableResult
    func perform(_ op: Operation) async throws -> String {
        let s = try signer()
        let (plan, env) = try await build(op, s)
        let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
        if case .offer = op, let o = plan.newOffer {
            registry.trackOffer(KachatNames.OfferInfo(
                outpoint: o.utxo.outpoint, key: o.fields.key, name: o.name, buyer: o.fields.buyer,
                amount: o.value, refundAfter: o.fields.refundAfter, createdAt: KachatNames.nowMs()))
        }
        registry.refreshAfter(txId: txId)
        return txId
    }

    // MARK: - Profile record

    /// Writes the address profile (`kchat:1:profile:`): a self-transfer, network fee only.
    @discardableResult
    func saveProfile(_ profile: KachatNames.Profile) async throws -> String {
        let s = try signer()
        let clean = profile.sanitized()
        let json = try clean.recordJSON()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let txId = try await service.submitProfileRecord(address: s.address, privateKey: s.privateKey, utxos: utxos, json: json)
        registry.noteOwnProfile(clean, address: s.address, txId: txId)
        registry.refreshAfter(txId: txId)
        return txId
    }

    // MARK: - Registration

    struct Quote: Equatable {
        var name: String
        var years: Int64
        /// price per year x years, left to miners
        var price: UInt64
        /// the name's bond, returned on release
        var bond: UInt64
        /// the extra registry gap the registration creates, returned on release
        var gapDeposit: UInt64
        /// the commit's value, returned into the registration
        var commit: UInt64
        var networkFee: UInt64
        /// what leaves the wallet in the end: price + bond + gap deposit + network fees
        var total: UInt64
        var spendable: UInt64

        var affordable: Bool { spendable >= total + KachatNames.minChange }
    }

    /// The cost of registering `name` for `years`, estimated by building both transactions
    /// (nothing is signed or sent).
    func quote(name: String, years: Int64, gap: KachatNames.GapInfo) async throws -> Quote {
        let s = try signer()
        let m = try await registry.prepare()
        let (b, env, wallet) = try await context(s)
        let salt = try KachatNamesService.newSalt()
        let spendable = wallet.reduce(UInt64(0)) { $0 + $1.entry.amount }
        let price = m.params.price(forLength: name.utf8.count) * UInt64(years)
        var commitFee: UInt64 = 0
        var registerFee: UInt64 = 0
        if let commitPlan = try? b.commit(env: env, wallet: wallet, name: name, salt: salt) {
            commitFee = commitPlan.networkFee
            // the registration, with the commit as if it were already mature and the gap as known
            if var commit = commitPlan.newCommit {
                commit.utxo?.entry.blockDaaScore = env.blockDaa > m.params.tCommit ? env.blockDaa - m.params.tCommit : 0
                let gapUtxo = KachatNames.Utxo(outpoint: gap.outpoint, entry: KachatNames.UtxoEntry(
                    amount: m.params.gapValue, script: m.gap.script(KachatNames.Codec.gapState(lo: gap.lo, hi: gap.hi)),
                    blockDaaScore: env.blockDaa, covenantId: m.registryCovenantId))
                let rest = wallet.filter { u in !commitPlan.inputs.contains { $0.utxo.outpoint == u.outpoint } }
                if let reg = try? b.register(env: env, wallet: rest, gap: KachatNames.GapRecord(lo: gap.lo, hi: gap.hi, value: m.params.gapValue, utxo: gapUtxo),
                                             commit: commit, years: years, now: KachatNames.Builder.registerNow(env: env)) {
                    registerFee = reg.networkFee
                }
            }
        }
        if registerFee == 0 { registerFee = 400_000 }
        if commitFee == 0 { commitFee = 250_000 }
        let fee = commitFee + registerFee
        return Quote(name: name, years: years, price: price, bond: m.params.bond, gapDeposit: m.params.gapValue,
                     commit: KachatNames.commitValue, networkFee: fee, total: price + m.params.bond + m.params.gapValue + fee,
                     spendable: spendable)
    }

    /// Starts registering `name`: a fresh salt (Keychain), the salted commit (submitted), then the
    /// driver registers once the commit is `tCommit` deep. Returns the commit txid.
    @discardableResult
    func startRegistration(name raw: String, years: Int64) async throws -> String {
        let s = try signer()
        let name = KachatNames.Codec.normalize(raw)
        try KachatNames.Codec.validate(name)
        await registry.refresh()
        switch try await registry.lookup(name) {
        case .registered:
            throw ActionError.notRegisterable(String(format: AppLocalization.string("%@ is already registered."), "\(name).kachat"))
        case .free:
            break
        }
        let (b, env, wallet) = try await context(s)
        let salt = try KachatNamesService.newSalt()
        let plan = try b.commit(env: env, wallet: wallet, name: name, salt: salt)
        guard let commit = plan.newCommit, let script = commit.utxo?.entry.script else { throw KachatNames.Failure("commit: no record") }
        let id = UUID().uuidString
        try KeychainService.shared.saveKachatCommitSalt(salt, id: id, walletAddress: s.address)
        let now = KachatNames.nowMs()
        var record = KachatNames.PendingRegistration(
            id: id, name: name, years: years, owner: KachatNames.hex(s.me), commitTxId: plan.unsignedTx.idHex,
            commitScript: KachatNames.hex(script), commitDaa: nil, registerTxId: nil, cancelTxId: nil,
            stage: .committing, createdAt: now, updatedAt: now, lastError: nil
        )
        loadPending(for: s.address)
        upsert(record)
        do {
            let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
            record.commitTxId = txId
            record.stage = .waiting
            record.updatedAt = KachatNames.nowMs()
            upsert(record)
        } catch {
            // The node may still have taken it: keep the record (and the salt) until the driver
            // sees the commit on chain or gives up on it.
            record.lastError = error.localizedDescription
            record.updatedAt = KachatNames.nowMs()
            upsert(record)
            startDriver()
            throw error
        }
        startDriver()
        return record.commitTxId
    }

    /// Spends the commit back (the name was taken, or the person changed their mind).
    @discardableResult
    func cancel(_ p: KachatNames.PendingRegistration) async throws -> String {
        let s = try signer()
        guard let salt = try KeychainService.shared.loadKachatCommitSalt(id: p.id, walletAddress: s.address) else { throw ActionError.noSalt }
        let b = try await service.builder()
        let env = try await service.environment(privateKey: s.privateKey, feerate: await feerate())
        let commitUtxo = try await service.liveUtxo(script: try KachatNames.unhex(p.commitScript), outpoint: try commitOutpoint(p))
        let plan = try b.cancelCommit(env: env, commit: KachatNames.CommitRecord(name: p.name, owner: s.me, salt: salt, value: commitUtxo.entry.amount, utxo: commitUtxo))
        let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
        var q = p
        q.cancelTxId = txId
        q.stage = .cancelling
        q.updatedAt = KachatNames.nowMs()
        upsert(q)
        startDriver()
        return txId
    }

    /// Try a failed registration again.
    func retry(_ p: KachatNames.PendingRegistration) {
        var q = p
        q.stage = .waiting
        q.lastError = nil
        q.updatedAt = KachatNames.nowMs()
        upsert(q)
        startDriver()
    }

    /// Drop a finished (registered or cancelled) registration from the list.
    func dismiss(_ p: KachatNames.PendingRegistration) {
        guard let address = pendingWallet else { return }
        remove(p.id, address: address)
    }

    /// Loads the current wallet's registrations and drives the open ones. Call on appear and
    /// when the app becomes active.
    func resume() {
        guard KachatNamesService.isEnabled, let address = myAddress else {
            driver?.cancel()
            driver = nil
            pending = []
            pendingWallet = nil
            return
        }
        loadPending(for: address)
        startDriver()
    }

    private func startDriver() {
        guard driver == nil, pending.contains(where: { $0.needsDriving }) else { return }
        driver = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard KachatNamesService.isEnabled, let address = self.myAddress, address == self.pendingWallet,
                      self.pending.contains(where: { $0.needsDriving }) else { break }
                for p in self.pending where p.needsDriving {
                    await self.advance(p)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            self?.driver = nil
        }
    }

    private func commitOutpoint(_ p: KachatNames.PendingRegistration) throws -> KachatNames.Outpoint {
        KachatNames.Outpoint(txid: try KachatNames.unhex32(p.commitTxId), index: 0)
    }

    /// The commit UTXO when a node has it (nil when spent or not yet accepted).
    private func liveCommit(_ p: KachatNames.PendingRegistration) async -> KachatNames.Utxo? {
        guard let script = try? KachatNames.unhex(p.commitScript), let op = try? commitOutpoint(p) else { return nil }
        return try? await service.liveUtxo(script: script, outpoint: op)
    }

    private func set(_ p: KachatNames.PendingRegistration, _ change: (inout KachatNames.PendingRegistration) -> Void) {
        var q = pending.first { $0.id == p.id } ?? p
        change(&q)
        q.updatedAt = KachatNames.nowMs()
        upsert(q)
    }

    /// One step of one registration.
    private func advance(_ p: KachatNames.PendingRegistration) async {
        let age = KachatNames.nowMs() - p.createdAt
        let sinceUpdate = KachatNames.nowMs() - p.updatedAt
        switch p.stage {
        case .committing, .waiting:
            guard let commit = await liveCommit(p) else {
                if p.commitDaa == nil && age < 10 * 60_000 { return }
                // the commit is gone: registered by us (another device?), or never confirmed
                if await ownsName(p.name) {
                    finishRegistered(p)
                } else {
                    let why = p.commitDaa == nil ? "The commit never reached the chain." : "The commit is no longer on chain."
                    set(p) { $0.stage = .failed; $0.lastError = AppLocalization.string(why) }
                }
                return
            }
            if p.commitDaa != commit.entry.blockDaaScore || p.stage == .committing {
                set(p) { $0.commitDaa = commit.entry.blockDaaScore; $0.stage = .waiting }
            }
            guard let m = service.manifest,
                  let dag = try? await NodePoolService.shared.currentDagPoint() else { return }
            virtualDaa = dag.virtualDaaScore
            // a little past maturity, so the block that takes it is surely deep enough
            guard dag.virtualDaaScore >= commit.entry.blockDaaScore + m.params.tCommit + 20 else { return }
            await register(p, commit: commit)
        case .registering:
            if let tx = p.registerTxId, await KachatNamesRegistry.isAccepted(txId: tx) {
                await registry.refresh()
                if await ownsName(p.name) { finishRegistered(p) }
                return
            }
            // not accepted after two minutes and the commit is still there: register again
            if sinceUpdate > 120_000, await liveCommit(p) != nil {
                set(p) { $0.stage = .waiting; $0.registerTxId = nil }
            }
        case .cancelling:
            if let tx = p.cancelTxId, await KachatNamesRegistry.isAccepted(txId: tx) {
                finishCancelled(p)
            } else if sinceUpdate > 120_000, await liveCommit(p) == nil {
                finishCancelled(p)
            }
        case .registered, .taken, .failed, .cancelled:
            break
        }
    }

    private func ownsName(_ name: String) async -> Bool {
        guard let me = myKey, case .registered(let n)? = try? await registry.lookup(name) else { return false }
        return n.owner == me
    }

    private func register(_ p: KachatNames.PendingRegistration, commit: KachatNames.Utxo) async {
        do {
            let s = try signer()
            guard KachatNames.hex(s.me) == p.owner else { return }
            guard let salt = try KeychainService.shared.loadKachatCommitSalt(id: p.id, walletAddress: s.address) else { throw ActionError.noSalt }
            await registry.refresh()
            let m = try await registry.prepare()
            let gap: KachatNames.GapInfo
            switch try await registry.lookup(p.name) {
            case .registered(let n):
                if n.owner == s.me { finishRegistered(p) } else { set(p) { $0.stage = .taken; $0.lastError = nil } }
                return
            case .free(_, let g):
                guard let g else { throw KachatNames.Failure("no gap for \(p.name) yet") }
                gap = g
            }
            let (b, env, wallet) = try await context(s)
            let plan = try b.register(
                env: env, wallet: wallet, gap: try await liveGap(gap, m),
                commit: KachatNames.CommitRecord(name: p.name, owner: s.me, salt: salt, value: commit.entry.amount, utxo: commit),
                years: p.years, now: KachatNames.Builder.registerNow(env: env)
            )
            let txId = try await service.signAndSubmit(plan, privateKey: s.privateKey, env: env)
            set(p) { $0.stage = .registering; $0.registerTxId = txId; $0.lastError = nil }
            registry.refreshAfter(txId: txId)
        } catch {
            let message = error.localizedDescription
            AppLog.log("[KachatNames] register %@ failed: %@", p.name, message)
            // funds and a missing salt need the person; anything else (a gap that just moved, a
            // node hiccup) is retried on the next tick
            let fatal = message.contains("insufficient funds") || (error as? ActionError) != nil
            set(p) {
                $0.lastError = message
                if fatal { $0.stage = .failed }
            }
        }
    }

    private func finishRegistered(_ p: KachatNames.PendingRegistration) {
        if let address = pendingWallet { try? KeychainService.shared.deleteKachatCommitSalt(id: p.id, walletAddress: address) }
        set(p) { $0.stage = .registered; $0.lastError = nil }
    }

    private func finishCancelled(_ p: KachatNames.PendingRegistration) {
        if let address = pendingWallet { try? KeychainService.shared.deleteKachatCommitSalt(id: p.id, walletAddress: address) }
        set(p) { $0.stage = .cancelled; $0.lastError = nil }
        if let address = pendingWallet { remove(p.id, address: address) }
    }

    // MARK: - Persistence (Application Support/KachatNames/<network>/pending-<wallet>.json)

    private static func file(_ address: String) -> String { "pending-\(KachatNamesRegistry.walletSuffix(address)).json" }

    private func loadPending(for address: String) {
        let address = address.lowercased()
        guard pendingWallet != address else { return }
        pendingWallet = address
        if let data = KachatNamesRegistry.readFile(Self.file(address)),
           let list = try? JSONDecoder().decode([KachatNames.PendingRegistration].self, from: data) {
            pending = list
        } else {
            pending = []
        }
    }

    private func save() {
        guard let address = pendingWallet, let data = try? JSONEncoder().encode(pending) else { return }
        KachatNamesRegistry.writeFile(Self.file(address), data)
    }

    private func upsert(_ p: KachatNames.PendingRegistration) {
        if let i = pending.firstIndex(where: { $0.id == p.id }) { pending[i] = p } else { pending.append(p) }
        save()
    }

    private func remove(_ id: String, address: String) {
        try? KeychainService.shared.deleteKachatCommitSalt(id: id, walletAddress: address)
        pending.removeAll { $0.id == id }
        save()
    }
}
