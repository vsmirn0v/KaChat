import Foundation

extension KachatNames {

    // MARK: - Compute budgets

    /// Which budget an input commits, by what it runs.
    enum BudgetRole: String, CaseIterable {
        case p2pk
        case commit
        case gapRegister = "gap.register"
        case gapMerge = "gap.merge"
        case gapAbsorbed = "gap.absorbed"
        /// registry v5 only: the CLI's sponsor imports; listed so the table matches the vectors
        case gapImport = "gap.import"
        case nameTransfer = "name.transfer"
        case nameList = "name.list"
        case nameBuy = "name.buy"
        case nameExtend = "name.extend"
        case nameRenew = "name.renew"
        case nameRelease = "name.release"
        case nameReclaim = "name.reclaim"
        case offerAccept = "offer.accept"
        case offerDecline = "offer.decline"
        case offerWithdraw = "offer.withdraw"
        case offerRefund = "offer.refund"
    }

    /// Per-input compute budgets. The CLI measures each input in the script engine; the app has no
    /// engine, so it commits a fixed budget per entry that covers every case (README "Cost per
    /// operation"; the vector generator checks every measured budget fits this table, the
    /// vectors' `recommendedBudgets`). An input that needs more than it committed fails, so these
    /// only ever err on the side of a slightly higher fee (100 grams per unit). Registry v4.
    struct Budgets: Equatable {
        var table: [BudgetRole: UInt16]

        static let recommended = Budgets(table: [
            .p2pk: 10, .commit: 10,
            .gapRegister: 8, .gapMerge: 4, .gapAbsorbed: 0, .gapImport: 0,
            .nameTransfer: 12, .nameList: 12, .nameBuy: 2, .nameExtend: 2, .nameRenew: 2, .nameRelease: 10, .nameReclaim: 0,
            .offerAccept: 17, .offerDecline: 10, .offerWithdraw: 10, .offerRefund: 0
        ])

        /// Registry v5: the gap is the v5 gap (7.7 kB: the 20-level import proof loop and a second
        /// name check), and every gap spend reveals and runs it. kachat-domains 6eddc7a measured
        /// the worst cases: register 122,889 script units (12), merge 69,090 (6), absorbed 15,782
        /// (1), import ~234,700 (23); the vectors' `recommendedBudgets`. Name and offer as v4.
        static let recommendedV5: Budgets = {
            var b = Budgets.recommended
            b[.gapRegister] = 13
            b[.gapMerge] = 7
            b[.gapAbsorbed] = 1
            b[.gapImport] = 24
            return b
        }()

        static func recommended(forRegistryVersion version: Int) -> Budgets {
            version >= 5 ? .recommendedV5 : .recommended
        }

        subscript(role: BudgetRole) -> UInt16 {
            get { table[role] ?? Budgets.recommended.table[role] ?? 0 }
            set { table[role] = newValue }
        }
    }

    // MARK: - Builder inputs

    /// Where and how a transaction is built: the signer's x-only key (owner, buyer and payer),
    /// the virtual's DAA score and past median time, the wall clock, the fee rate.
    struct Env {
        var me: Data
        var blockDaa: UInt64
        /// The virtual's past median time, unix ms.
        var blockTimeMs: UInt64
        var wallMs: Int64
        var feerate: Double = KachatNames.minFeerate
        var budgets: Budgets = .recommended
    }

    struct GapRecord: Equatable {
        var lo: Data
        var hi: Data
        var value: UInt64
        var utxo: Utxo
    }

    struct NameRecord: Equatable {
        var fields: NameFields
        var value: UInt64
        var utxo: Utxo
        var name: String { fields.name }
    }

    struct OfferRecord: Equatable {
        var fields: OfferFields
        var value: UInt64
        var utxo: Utxo
        /// The wanted name when known (the state holds only its key).
        var name: String?
    }

    /// A salted commit. `utxo` is nil until the commit transaction is accepted.
    struct CommitRecord: Equatable {
        var name: String
        var owner: Data
        var salt: Data
        var value: UInt64
        var utxo: Utxo?
    }

    /// The three registry UTXOs of an exit: gap (lo, key), the name, gap (key, hi).
    struct ExitParts {
        var below: GapRecord
        var name: NameRecord
        var above: GapRecord
    }

    // MARK: - Unsigned plan

    enum Arg: Equatable {
        case bytes(Data)
        case int(Int64)
        /// A SIGHASH_ALL Schnorr signature by `Env.me` over the input it sits in.
        case signature
    }

    enum Unlock: Equatable {
        case p2pk
        case commit(redeem: Data)
        /// `<args> <dispatch tag> <push(redeem)>`
        case contract(redeem: Data, tag: Data, args: [Arg])

        var needsSignature: Bool {
            switch self {
            case .p2pk, .commit: return true
            case .contract(_, _, let args): return args.contains(.signature)
            }
        }

        /// The signature script with `signature` (65 bytes: 64-byte Schnorr + sighash type).
        func signatureScript(signature: Data) -> Data {
            switch self {
            case .p2pk:
                return Codec.pushData(signature)
            case .commit(let redeem):
                return Codec.pushData(signature) + Codec.pushData(redeem)
            case .contract(let redeem, let tag, let args):
                var s = Data()
                for a in args {
                    switch a {
                    case .bytes(let b): s.append(Codec.pushData(b))
                    case .int(let v): s.append(Codec.pushInt(v))
                    case .signature: s.append(Codec.pushData(signature))
                    }
                }
                s.append(Codec.pushData(tag))
                s.append(Codec.pushData(redeem))
                return s
            }
        }
    }

    struct PlannedInput: Equatable {
        var utxo: Utxo
        var sequence: UInt64 = 0
        var unlock: Unlock
        var role: BudgetRole
        var label: String
    }

    struct PlannedOutput: Equatable {
        var output: TxOutput
        var label: String
    }

    struct Costs: Equatable {
        var size: UInt64
        var computeMass: UInt64
        var transientMass: UInt64
        var normalizedTransient: UInt64
        var storageMass: UInt64
        /// 100 sompi/gram over max(compute, normalized transient)
        var minFee: UInt64
    }

    /// A built, not yet signed transaction: placeholder signatures of the right length sit in
    /// the signature scripts, so sizes, masses and the fee are final. `signed(by:)` fills them.
    struct Plan {
        var op: String
        var inputs: [PlannedInput]
        var outputs: [PlannedOutput]
        /// The transaction with placeholder signatures.
        var unsignedTx: Tx
        var entries: [UtxoEntry]
        var costs: Costs
        /// Price paid as miner fee (register / extend / renew).
        var priceFee: UInt64
        var networkFee: UInt64
        var notes: [String]
        /// `commit`: the record to keep (with its salt!) once the transaction is accepted.
        var newCommit: CommitRecord?
        /// `offer`: the offer to track once accepted.
        var newOffer: OfferRecord?

        var fee: UInt64 { priceFee + networkFee }
        var txid: Data { unsignedTx.id }

        /// Every input's SIGHASH_ALL Schnorr sighash (signature scripts do not enter it).
        var sighashes: [Data] { (0..<inputs.count).map { unsignedTx.sighash(inputIndex: $0, entries: entries) } }

        /// The signed transaction. `sign` returns the 64-byte BIP-340 Schnorr signature of a
        /// 32-byte sighash by `Env.me`'s key; it is called once per input that needs one.
        func signed(by sign: (Data) throws -> Data) throws -> Tx {
            var tx = unsignedTx
            for (i, input) in inputs.enumerated() where input.unlock.needsSignature {
                let sig = try sign(unsignedTx.sighash(inputIndex: i, entries: entries))
                guard sig.count == 64 else { throw Failure("a Schnorr signature is 64 bytes") }
                tx.inputs[i].signatureScript = input.unlock.signatureScript(signature: sig + Data([sighashAll]))
            }
            return tx
        }

        /// The signed transaction from ready 65-byte signatures (signature + sighash type) by
        /// input index (test vectors, external signers).
        func signed(signatures: [Int: Data]) throws -> Tx {
            var tx = unsignedTx
            for (i, input) in inputs.enumerated() where input.unlock.needsSignature {
                guard let sig = signatures[i], sig.count == 65 else { throw Failure("no 65-byte signature for input \(i)") }
                tx.inputs[i].signatureScript = input.unlock.signatureScript(signature: sig)
            }
            return tx
        }
    }

    // MARK: - Builder

    /// The transaction builders of the kachat-domains CLI (`tools/kachat-names-cli/src/ops.rs`),
    /// ported one to one: same shapes, payloads, lock times, sequences, coin selection, change
    /// and fee rule. Pure: they read decoded registry records with their live UTXOs and the
    /// signer's spendable P2PK UTXOs, and never touch the network.
    struct Builder {
        let manifest: Manifest

        /// Only over a verified testnet-10 manifest (`Manifest.verify`): the builders never run
        /// against an unverified registry or another network.
        init(manifest: Manifest) throws {
            try manifest.verify()
            self.manifest = manifest
        }

        var params: Params { manifest.params }
        var registryId: Data { manifest.registryCovenantId }

        private static let placeholderSignature = Data(repeating: 0, count: 64) + Data([sighashAll])

        // MARK: Shared assembly

        private enum FeeMode {
            /// add the signer's funding inputs and a change output back to the signer
            case funded(maxInputs: Int)
            /// no funding: take the network fee out of output `index`, which must keep `floor`
            case fromOutput(index: Int, cap: UInt64?, floor: UInt64 = KachatNames.minChange)
        }

        private struct Draft {
            var op: String
            var inputs: [PlannedInput]
            var outputs: [PlannedOutput]
            var lockTime: UInt64 = 0
            var priceFee: UInt64 = 0
            var notes: [String] = []
            var payload = Data()
        }

        private func assemble(_ inputs: [PlannedInput], _ outputs: [PlannedOutput], lockTime: UInt64, payload: Data, env: Env) -> (Tx, [UtxoEntry]) {
            let entries = inputs.map { $0.utxo.entry }
            var tx = Tx(
                inputs: inputs.map {
                    TxInput(
                        outpoint: $0.utxo.outpoint,
                        signatureScript: $0.unlock.signatureScript(signature: Builder.placeholderSignature),
                        sequence: $0.sequence,
                        computeBudget: env.budgets[$0.role]
                    )
                },
                outputs: outputs.map { $0.output },
                lockTime: lockTime,
                payload: payload
            )
            // KIP-9 storage-mass commitment (independent of signature scripts)
            if let m = Mass.storageMass(tx, entries: entries) {
                tx.storageMass = m
            }
            return (tx, entries)
        }

        static func costs(_ tx: Tx) -> Costs {
            let compute = Mass.computeMass(tx)
            let normalized = Mass.normalizedTransient(tx)
            return Costs(
                size: Mass.size(tx), computeMass: compute, transientMass: Mass.transientMass(tx),
                normalizedTransient: normalized, storageMass: tx.storageMass,
                minFee: max(compute, normalized) * 100
            )
        }

        /// Pick funding UTXOs (largest first, then lowest output index, skipping `used`) worth at
        /// least `target`, at most `slots` of them. Returns what it found even if short.
        private static func select(_ wallet: [Utxo], used: [Outpoint], target: UInt64, slots: Int) -> [Utxo] {
            let pool = wallet.enumerated().filter { !used.contains($0.element.outpoint) }
            let sorted = pool.sorted { a, b in
                if a.element.entry.amount != b.element.entry.amount { return a.element.entry.amount > b.element.entry.amount }
                if a.element.outpoint.index != b.element.outpoint.index { return a.element.outpoint.index < b.element.outpoint.index }
                return a.offset < b.offset
            }
            var out: [Utxo] = []
            var sum: UInt64 = 0
            for (_, u) in sorted {
                if sum >= target || out.count >= slots { break }
                sum += u.entry.amount
                out.append(u)
            }
            return out
        }

        private static func kas(_ sompi: UInt64) -> String {
            String(format: "%llu.%08llu TKAS", sompi / sompiPerKas, sompi % sompiPerKas)
        }

        private func finish(_ draftIn: Draft, wallet: [Utxo], fee: FeeMode, env: Env) throws -> Plan {
            var d = draftIn
            let networkFee: UInt64
            switch fee {
            case .funded(let maxInputs):
                let fixedIn = d.inputs.reduce(UInt64(0)) { $0 + $1.utxo.entry.amount }
                let fixedOut = d.outputs.reduce(UInt64(0)) { $0 + $1.output.value }
                let used = d.inputs.map { $0.utxo.outpoint }
                let slots = max(0, maxInputs - d.inputs.count)
                var est: UInt64 = 0
                var last: (inputs: [PlannedInput], outputs: [PlannedOutput], change: UInt64, withChange: Bool)?
                for _ in 0..<5 {
                    let required = fixedOut + d.priceFee + est
                    let need = required > fixedIn ? required - fixedIn : 0
                    var picked = Builder.select(wallet, used: used, target: need + targetChange, slots: slots)
                    var have = picked.reduce(UInt64(0)) { $0 + $1.entry.amount }
                    if have < need + minChange && need > 0 {
                        picked = Builder.select(wallet, used: used, target: need + minChange, slots: slots)
                    }
                    have = picked.reduce(UInt64(0)) { $0 + $1.entry.amount }
                    if fixedIn + have < required {
                        let all = wallet.filter { !used.contains($0.outpoint) }.reduce(UInt64(0)) { $0 + $1.entry.amount }
                        let bound = slots < wallet.count ? " (at most \(slots) funding inputs fit)" : ""
                        throw Failure(
                            "\(d.op): insufficient funds: need \(Builder.kas(required - fixedIn)) more (outputs \(Builder.kas(fixedOut)) + price "
                                + "\(Builder.kas(d.priceFee)) + network fee ~\(Builder.kas(est))), \(Builder.kas(all)) spendable\(bound)"
                        )
                    }
                    var inputs = d.inputs
                    for u in picked {
                        inputs.append(PlannedInput(utxo: u, unlock: .p2pk, role: .p2pk, label: "funding (P2PK)"))
                    }
                    let change = fixedIn + have - required
                    var outputs = d.outputs
                    let withChange = change >= minChange
                    if withChange {
                        outputs.append(PlannedOutput(output: TxOutput(value: change, script: Codec.p2pkScript(env.me)), label: "change"))
                    }
                    let (tx, _) = assemble(inputs, outputs, lockTime: d.lockTime, payload: d.payload, env: env)
                    let feeNow = Mass.networkFee(tx, feerate: env.feerate)
                    if feeNow <= est {
                        if !withChange && change > 0 {
                            d.notes.append("no change output: the \(Builder.kas(change)) left over goes to the miner")
                        }
                        last = (inputs, outputs, change, withChange)
                        break
                    }
                    est = feeNow
                }
                guard let l = last else { throw Failure("\(d.op): fee did not converge") }
                d.inputs = l.inputs
                d.outputs = l.outputs
                networkFee = l.withChange ? est : est + l.change
            case .fromOutput(let index, let cap, let floor):
                let totalIn = d.inputs.reduce(UInt64(0)) { $0 + $1.utxo.entry.amount }
                let others = d.outputs.enumerated().filter { $0.offset != index }.reduce(UInt64(0)) { $0 + $1.element.output.value }
                // provisional value (zero would break the KIP-9 storage-mass formula)
                let taken = others + d.priceFee
                d.outputs[index].output.value = max(totalIn > taken ? totalIn - taken : 0, 1)
                let (tx, _) = assemble(d.inputs, d.outputs, lockTime: d.lockTime, payload: d.payload, env: env)
                let f = Mass.networkFee(tx, feerate: env.feerate)
                if let cap = cap, f > cap {
                    throw Failure("\(d.op): network fee \(Builder.kas(f)) exceeds the contract's maxFee \(Builder.kas(cap))")
                }
                guard totalIn >= taken + f else { throw Failure("\(d.op): inputs do not cover the outputs and the fee") }
                let v = totalIn - taken - f
                guard v >= floor else { throw Failure("\(d.op): output \(index) would be only \(Builder.kas(v))") }
                d.outputs[index].output.value = v
                networkFee = f
            }
            guard d.inputs.count <= 255, d.outputs.count <= 255 else { throw Failure("too many inputs/outputs") }
            let (tx, entries) = assemble(d.inputs, d.outputs, lockTime: d.lockTime, payload: d.payload, env: env)
            let totalIn = entries.reduce(UInt64(0)) { $0 + $1.amount }
            let totalOut = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
            guard totalIn >= totalOut, totalIn - totalOut == d.priceFee + networkFee else {
                throw Failure("\(d.op): fee bookkeeping does not balance")
            }
            return Plan(
                op: d.op, inputs: d.inputs, outputs: d.outputs, unsignedTx: tx, entries: entries,
                costs: Builder.costs(tx), priceFee: d.priceFee, networkFee: networkFee, notes: d.notes,
                newCommit: nil, newOffer: nil
            )
        }

        // MARK: Checks

        private func checkLive(_ label: String, _ utxo: Utxo, value: UInt64, covenant: Data?) throws {
            guard utxo.entry.amount == value else {
                throw Failure("\(label): live UTXO holds \(Builder.kas(utxo.entry.amount)), not \(Builder.kas(value))")
            }
            guard utxo.entry.covenantId == covenant else { throw Failure("\(label): live UTXO has the wrong covenant id") }
        }

        private func requireOwner(_ env: Env, _ n: NameRecord) throws {
            guard n.fields.owner == env.me else { throw Failure("\(n.name) is owned by another key") }
        }

        private static func checkKey(_ key: Data, _ what: String) throws {
            guard key.count == 32, key != zero32 else { throw Failure("\(what) must be a non-zero 32-byte x-only key") }
        }

        private func registryOutput(value: UInt64, script: Data) -> TxOutput {
            TxOutput(value: value, script: script, covenant: CovenantBinding(authorizingInput: 0, covenantId: registryId))
        }

        private func gapOutput(lo: Data, hi: Data) -> TxOutput {
            registryOutput(value: params.gapValue, script: manifest.gap.script(Codec.gapState(lo: lo, hi: hi)))
        }

        private func nameOutput(_ f: NameFields) -> TxOutput {
            registryOutput(value: params.bond, script: manifest.name.script(f.encoded))
        }

        private func nameInput(_ n: NameRecord, _ entry: String, _ args: [Arg], role: BudgetRole, label: String) throws -> PlannedInput {
            let unlock = Unlock.contract(redeem: manifest.name.redeem(n.fields.encoded), tag: try manifest.name.tag(entry), args: args)
            return PlannedInput(utxo: n.utxo, unlock: unlock, role: role, label: label)
        }

        private func gapInput(_ g: GapRecord, _ entry: String, _ args: [Arg], role: BudgetRole, label: String) throws -> PlannedInput {
            let unlock = Unlock.contract(redeem: manifest.gap.redeem(Codec.gapState(lo: g.lo, hi: g.hi)), tag: try manifest.gap.tag(entry), args: args)
            return PlannedInput(utxo: g.utxo, unlock: unlock, role: role, label: label)
        }

        private func offerInput(_ o: OfferRecord, _ entry: String, _ args: [Arg], role: BudgetRole, label: String) throws -> PlannedInput {
            let unlock = Unlock.contract(redeem: manifest.offer.redeem(o.fields.encoded), tag: try manifest.offer.tag(entry), args: args)
            return PlannedInput(utxo: o.utxo, unlock: unlock, role: role, label: label)
        }

        // MARK: Commit / register

        /// A salted commit: `P2SH(0x20 c 0x75 0x20 ownerKey 0xac)` worth 0.2 KAS, no payload (a
        /// payload would reveal the name). Keep `newCommit` (the salt) until the registration.
        func commit(env: Env, wallet: [Utxo], name: String, salt: Data) throws -> Plan {
            try Codec.validate(name)
            guard salt.count == 32 else { throw Failure("the salt is 32 bytes") }
            let c = Codec.commitment(name: name, owner: env.me, salt: salt)
            let redeem = Codec.commitRedeem(commitment: c, owner: env.me)
            let out = TxOutput(value: commitValue, script: Codec.p2shScript(redeem))
            let d = Draft(op: "commit \(name)", inputs: [], outputs: [PlannedOutput(output: out, label: "commit P2SH")])
            var plan = try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputs), env: env)
            let entry = UtxoEntry(amount: commitValue, script: out.script, blockDaaScore: 0, covenantId: nil)
            plan.newCommit = CommitRecord(
                name: name, owner: env.me, salt: salt, value: commitValue,
                utxo: Utxo(outpoint: Outpoint(txid: plan.txid, index: 0), entry: entry)
            )
            return plan
        }

        /// `now` for a registration: wall clock - 3 min (the median time lags ~2.2 min), never at
        /// or past the virtual's median time.
        static func registerNow(env: Env) -> Int64 {
            min(env.wallMs - 180_000, Int64(env.blockTimeMs) - 1_000)
        }

        /// Register `commit.name` for `years` periods: [gap.register, commit, funding] -> [gap
        /// (lo,key), gap (key,hi), name (periodStart = now), change]; lock time `now`, commit
        /// sequence `tCommit`. The price is the baked one (registry v4): the registration price
        /// for the first period, the renewal price for each further one.
        func register(env: Env, wallet: [Utxo], gap: GapRecord, commit: CommitRecord, years: Int64, now: Int64) throws -> Plan {
            let name = commit.name
            try Codec.validate(name)
            guard commit.owner == env.me else { throw Failure("the commit for \(name) is for another owner") }
            guard let commitUtxo = commit.utxo else { throw Failure("the commit for \(name) is not on chain yet") }
            guard years >= 1, years <= params.maxYears else { throw Failure("years must be 1..\(params.maxYears)") }
            let key = Codec.key(name)
            guard gap.lo.lexicographicallyPrecedes(key), key.lexicographicallyPrecedes(gap.hi) else {
                throw Failure("\(name) is not inside that gap")
            }
            try checkLive("gap", gap.utxo, value: params.gapValue, covenant: registryId)
            let redeem = Codec.commitRedeem(commitment: Codec.commitment(name: name, owner: env.me, salt: commit.salt), owner: env.me)
            guard commitUtxo.entry.script == Codec.p2shScript(redeem) else { throw Failure("commit UTXO script does not match the salt") }
            guard now > 0, UInt64(now) >= lockTimeThreshold else { throw Failure("now must be a unix-ms timestamp") }
            // registry v5: closed until the migration deadline (the contract refuses it)
            guard params.registerOpen(atMs: now) else {
                throw Failure.registrationNotOpen(params.migration?.deadlineMs ?? 0)
            }

            let nameLength = name.utf8.count
            let price = params.registerCost(forLength: nameLength, years: years)
            let expires = now + years * params.periodMs
            let fields = NameFields(name: name, owner: env.me, price: 0, periodStart: now, expiresAt: expires)
            var notes: [String] = []
            let matureAt = commitUtxo.entry.blockDaaScore + params.tCommit
            if env.blockDaa < matureAt {
                notes.append("commit not mature yet: valid from DAA \(matureAt) (now \(env.blockDaa))")
            }
            if expires + params.graceMs < env.wallMs {
                notes.append("backdated: this name is already past expiresAt + grace (reclaimable at once)")
            } else if expires < env.wallMs {
                notes.append("backdated: this name is already expired (in grace)")
            }
            let gapIn = try gapInput(
                gap, "register",
                [.bytes(Data(name.utf8)), .bytes(env.me), .bytes(commit.salt), .int(now), .int(years),
                 .bytes(manifest.name.prefix), .bytes(manifest.name.suffix)],
                role: .gapRegister, label: "gap register"
            )
            let commitIn = PlannedInput(utxo: commitUtxo, sequence: params.tCommit, unlock: .commit(redeem: redeem), role: .commit, label: "commit for \(name)")
            var d = Draft(
                op: "register \(name) (\(years) period(s))",
                inputs: [gapIn, commitIn],
                outputs: [
                    PlannedOutput(output: gapOutput(lo: gap.lo, hi: key), label: "gap (lo, key)"),
                    PlannedOutput(output: gapOutput(lo: key, hi: gap.hi), label: "gap (key, hi)"),
                    PlannedOutput(output: nameOutput(fields), label: "name \(name)")
                ]
            )
            d.lockTime = UInt64(now)
            d.priceFee = price
            d.notes = notes
            d.payload = Codec.namePayload(op: "register", name: name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputsFeeEntry), env: env)
        }

        /// Spend an unused commit back to its owner (the name was taken meanwhile, or the owner
        /// changed their mind): [commit (owner sig + redeem)] -> [P2PK(owner), the commit's value
        /// less the network fee]. No funding, no payload (the name stays hidden), sequence 0.
        func cancelCommit(env: Env, commit: CommitRecord) throws -> Plan {
            guard commit.owner == env.me else { throw Failure("the commit for \(commit.name) is for another owner") }
            guard let u = commit.utxo else { throw Failure("the commit for \(commit.name) is not on chain") }
            guard commit.salt.count == 32 else { throw Failure("the salt is 32 bytes") }
            let redeem = Codec.commitRedeem(commitment: Codec.commitment(name: commit.name, owner: env.me, salt: commit.salt), owner: env.me)
            guard u.entry.script == Codec.p2shScript(redeem) else { throw Failure("commit UTXO script does not match the salt") }
            guard u.entry.covenantId == nil else { throw Failure("a commit carries no covenant id") }
            let d = Draft(
                op: "cancel commit \(commit.name)",
                inputs: [PlannedInput(utxo: u, unlock: .commit(redeem: redeem), role: .commit, label: "commit for \(commit.name) (owner sig)")],
                outputs: [PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(env.me)), label: "back to the owner")]
            )
            return try finish(d, wallet: [], fee: .fromOutput(index: 0, cap: nil, floor: cancelFloor), env: env)
        }

        /// The least a cancelled commit may return (its storage mass stays small: one 0.2 KAS
        /// input, one output just under it).
        static let cancelFloorValue: UInt64 = 10_000_000
        private var cancelFloor: UInt64 { Builder.cancelFloorValue }

        // MARK: Name entries

        /// The lock time of a renewal (ops.rs `renew_lock_time`): the registration-style `now`, but
        /// never before the window opens -
        /// `max(min(wall - 3 min, median time - 1 s), expiresAt - renewWindowMs)` (unix ms).
        /// Final (and so valid) only while it is below the median time, i.e. once the window opened.
        static func renewLockTime(env: Env, params: Params, expiresAt: Int64) -> Int64 {
            max(registerNow(env: env), params.renewOpens(expiresAt: expiresAt))
        }

        /// Whether the renewal window is open at `env` (ops.rs `renew_window_open`): the virtual's
        /// past median time is past `expiresAt - renewWindowMs`. Before that no renewal is valid
        /// (the mempool keeps no future-dated transactions), so the app refuses to submit one.
        static func renewWindowOpen(env: Env, params: Params, expiresAt: Int64) -> Bool {
            Int64(env.blockTimeMs) > params.renewOpens(expiresAt: expiresAt)
        }

        /// Anyone extends the current period (a gift needs no signature): [name.extend(years),
        /// funding] -> [continuation (periodStart kept, expiresAt + years periods), change]. Lock
        /// time 0, every sequence 0. Valid any time while `expiresAt + years <= periodStart +
        /// maxYears` (in periods). Pays the renewal price per period.
        func extend(env: Env, wallet: [Utxo], name n: NameRecord, years: Int64) throws -> Plan {
            guard years >= 1, years <= params.maxYears else { throw Failure("years must be 1..\(params.maxYears)") }
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            let f = n.fields
            let room = params.extendableYears(f)
            guard years <= room else {
                throw Failure(
                    "extend \(n.name) by \(years) period(s) refused: it may be paid at most \(params.maxYears) periods past \(f.periodStart) and it is "
                        + "paid until \(f.expiresAt), so \(room) can be added now; renew opens at \(params.renewOpens(expiresAt: f.expiresAt))"
                )
            }
            let price = params.renewPrice(forLength: n.name.utf8.count) * UInt64(years)
            let nf = f.extended(years, periodMs: params.periodMs)
            var d = Draft(
                op: "extend \(n.name) (\(years) period(s))",
                inputs: [try nameInput(n, "extend", [.int(years)], role: .nameExtend, label: "name extend(\(years))")],
                outputs: [PlannedOutput(output: nameOutput(nf), label: "name \(n.name)")]
            )
            d.priceFee = price
            d.notes = [
                "extension price \(Builder.kas(price)) left as miner fee",
                "expiresAt \(f.expiresAt) -> \(nf.expiresAt); periodStart \(f.periodStart) kept (at most \(params.maxYears) periods past it)"
            ]
            d.payload = Codec.namePayload(op: "extend", name: n.name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputsFeeEntry), env: env)
        }

        /// Anyone renews once the renewal window opened: [name.renew(years), funding] ->
        /// [continuation (periodStart = old expiresAt, expiresAt + years periods), change]. Pays the
        /// renewal price per period. Lock time =
        /// `renewLockTime` (timestamp domain), every input sequence 0 (not final, as the CLTV
        /// needs). Before the window opens the plan is built but not valid (a note says so); the
        /// actions refuse to submit it.
        func renew(env: Env, wallet: [Utxo], name n: NameRecord, years: Int64) throws -> Plan {
            guard years >= 1, years <= params.maxYears else { throw Failure("years must be 1..\(params.maxYears)") }
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            let f = n.fields
            let opens = params.renewOpens(expiresAt: f.expiresAt)
            guard opens >= 0, UInt64(opens) >= lockTimeThreshold else { throw Failure("\(n.name): expiresAt - renewWindowMs is not a timestamp") }
            let lock = Builder.renewLockTime(env: env, params: params, expiresAt: f.expiresAt)
            let price = params.renewPrice(forLength: n.name.utf8.count) * UInt64(years)
            let nf = f.renewed(years, periodMs: params.periodMs)
            var d = Draft(
                op: "renew \(n.name) (\(years) period(s))",
                inputs: [try nameInput(n, "renew", [.int(years)], role: .nameRenew, label: "name renew(\(years))")],
                outputs: [PlannedOutput(output: nameOutput(nf), label: "name \(n.name)")]
            )
            d.lockTime = UInt64(lock)
            d.priceFee = price
            d.notes = [
                "renewal price \(Builder.kas(price)) left as miner fee",
                "new period: periodStart \(f.periodStart) -> \(nf.periodStart) (the old expiry), expiresAt -> \(nf.expiresAt)",
                "lock time \(lock) >= window opening expiresAt - renewWindowMs = \(opens)"
            ]
            if !Builder.renewWindowOpen(env: env, params: params, expiresAt: f.expiresAt) {
                d.notes.append("renewal window not open: it opens at \(opens) (the network median time \(env.blockTimeMs) must pass it); use extend to add periods before")
            }
            d.payload = Codec.namePayload(op: "renew", name: n.name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputsFeeEntry), env: env)
        }

        /// The owner transfers: new owner, listing cleared, period and expiry kept.
        func transfer(env: Env, wallet: [Utxo], name n: NameRecord, newOwner: Data) throws -> Plan {
            try requireOwner(env, n)
            try Builder.checkKey(newOwner, "the new owner")
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            var d = Draft(
                op: "transfer \(n.name)",
                inputs: [try nameInput(n, "transfer", [.bytes(newOwner), .signature], role: .nameTransfer, label: "name transfer (owner sig)")],
                outputs: [PlannedOutput(output: nameOutput(n.fields.withOwner(newOwner)), label: "name \(n.name)")]
            )
            d.payload = Codec.namePayload(op: "transfer", name: n.name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputs), env: env)
        }

        /// The owner lists at `price` sompi (0 = delist).
        func list(env: Env, wallet: [Utxo], name n: NameRecord, price: UInt64) throws -> Plan {
            try requireOwner(env, n)
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            guard price <= maxListPrice else { throw Failure("price above the supply") }
            var d = Draft(
                op: price == 0 ? "delist \(n.name)" : "list \(n.name) at \(Builder.kas(price))",
                inputs: [try nameInput(n, "list", [.int(Int64(price)), .signature], role: .nameList, label: "name list (owner sig)")],
                outputs: [PlannedOutput(output: nameOutput(n.fields.withPrice(Int64(price))), label: "name \(n.name)")]
            )
            if n.fields.expiresAt <= env.wallMs {
                d.notes.append("the name is expired: the app refuses to list a name in grace")
            }
            d.payload = Codec.namePayload(op: "list", name: n.name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputs), env: env)
        }

        /// The signer buys a listed name: [name.buy(me), funding] -> [continuation, payout of the
        /// price to P2PK(owner) right after it, change].
        func buy(env: Env, wallet: [Utxo], name n: NameRecord) throws -> Plan {
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            guard n.fields.price > 0 else { throw Failure("\(n.name) is not listed") }
            var d = Draft(
                op: "buy \(n.name) for \(Builder.kas(UInt64(n.fields.price)))",
                inputs: [try nameInput(n, "buy", [.bytes(env.me)], role: .nameBuy, label: "name buy(me)")],
                outputs: [
                    PlannedOutput(output: nameOutput(n.fields.withOwner(env.me)), label: "name \(n.name)"),
                    PlannedOutput(output: TxOutput(value: UInt64(n.fields.price), script: Codec.p2pkScript(n.fields.owner)), label: "payout to the seller")
                ]
            )
            if n.fields.expiresAt - params.expiresSoonMs < env.wallMs {
                d.notes.append("expires soon: the buyer will have to renew it")
            }
            d.payload = Codec.namePayload(op: "buy", name: n.name)
            return try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputs), env: env)
        }

        // MARK: Offers

        /// Lock `amount` sompi for the registered name `target`, made to its current owner
        /// (registry v3: only that owner can accept or decline it, so a change of owner ends it),
        /// refundable by anyone from DAA `refundAfter`; the transaction carries the
        /// `kchat:1:offer:` marker (with the seller).
        func offer(env: Env, wallet: [Utxo], target: NameRecord, amount: UInt64, refundAfter: UInt64) throws -> Plan {
            let name = target.name
            try Codec.validate(name)
            guard amount > params.offerMaxFee + minChange else { throw Failure("offer too small") }
            guard refundAfter < lockTimeThreshold else { throw Failure("refundAfter is a DAA score") }
            let fields = OfferFields(key: Codec.key(name), buyer: env.me, seller: target.fields.owner, refundAfter: Int64(refundAfter))
            let out = TxOutput(value: amount, script: manifest.offer.script(fields.encoded))
            var d = Draft(op: "offer \(Builder.kas(amount)) on \(name)", inputs: [], outputs: [PlannedOutput(output: out, label: "offer P2SH")])
            if target.fields.price > 0, UInt64(target.fields.price) <= amount {
                d.notes.append("\(name) is listed at or below this offer: buying it may be cheaper")
            }
            d.payload = Codec.offerPayload(fields)
            var plan = try finish(d, wallet: wallet, fee: .funded(maxInputs: maxInputs), env: env)
            let entry = UtxoEntry(amount: amount, script: out.script, blockDaaScore: 0, covenantId: nil)
            plan.newOffer = OfferRecord(fields: fields, value: amount, utxo: Utxo(outpoint: Outpoint(txid: plan.txid, index: 0), entry: entry), name: name)
            return plan
        }

        /// The owner accepts: [name.transfer(buyer, sig), offer.accept(0, sellerSig)] ->
        /// [continuation to the buyer, payout to the owner = offer - fee (fee <= maxFee)]. Only an
        /// offer made to this owner (registry v3).
        func acceptOffer(env: Env, name n: NameRecord, offer o: OfferRecord) throws -> Plan {
            try requireOwner(env, n)
            guard o.fields.seller == env.me else { throw Failure("that offer was made to an earlier owner of \(n.name)") }
            try checkLive(n.name, n.utxo, value: params.bond, covenant: registryId)
            try checkLive("offer", o.utxo, value: o.value, covenant: nil)
            guard o.fields.key == n.fields.key else { throw Failure("that offer is for another name") }
            var d = Draft(
                op: "accept offer \(Builder.kas(o.value)) on \(n.name)",
                inputs: [
                    try nameInput(n, "transfer", [.bytes(o.fields.buyer), .signature], role: .nameTransfer, label: "name transfer(buyer) (owner sig)"),
                    try offerInput(o, "accept", [.int(0), .signature], role: .offerAccept, label: "offer accept(0) (seller sig)")
                ],
                outputs: [
                    PlannedOutput(output: nameOutput(n.fields.withOwner(o.fields.buyer)), label: "name \(n.name) -> buyer"),
                    PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(n.fields.owner)), label: "payout to the owner")
                ]
            )
            d.payload = Codec.namePayload(op: "accept", name: n.name)
            return try finish(d, wallet: [], fee: .fromOutput(index: 1, cap: params.offerMaxFee), env: env)
        }

        /// The seller turns an offer down (registry v3): [offer.decline(sellerSig)] alone -> [back to
        /// the buyer, the offer less the network fee (<= maxFee)].
        func declineOffer(env: Env, offer o: OfferRecord) throws -> Plan {
            guard o.fields.seller == env.me else { throw Failure("only the seller can decline this offer") }
            try checkLive("offer", o.utxo, value: o.value, covenant: nil)
            let d = Draft(
                op: "decline offer \(Builder.kas(o.value))",
                inputs: [try offerInput(o, "decline", [.signature], role: .offerDecline, label: "offer decline (seller sig)")],
                outputs: [PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(o.fields.buyer)), label: "back to the buyer")]
            )
            return try finish(d, wallet: [], fee: .fromOutput(index: 0, cap: params.offerMaxFee), env: env)
        }

        /// The buyer takes the offer back.
        func withdrawOffer(env: Env, offer o: OfferRecord) throws -> Plan {
            guard o.fields.buyer == env.me else { throw Failure("only the buyer can withdraw this offer") }
            try checkLive("offer", o.utxo, value: o.value, covenant: nil)
            let d = Draft(
                op: "withdraw offer \(Builder.kas(o.value))",
                inputs: [try offerInput(o, "withdraw", [.signature], role: .offerWithdraw, label: "offer withdraw (buyer sig)")],
                outputs: [PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(o.fields.buyer)), label: "back to the buyer")]
            )
            return try finish(d, wallet: [], fee: .fromOutput(index: 0, cap: nil), env: env)
        }

        /// Anyone refunds once DAA > refundAfter: 1 input, 1 output, lock time = refundAfter.
        func refundOffer(env: Env, offer o: OfferRecord) throws -> Plan {
            try checkLive("offer", o.utxo, value: o.value, covenant: nil)
            var d = Draft(
                op: "refund offer \(Builder.kas(o.value))",
                inputs: [try offerInput(o, "refund", [], role: .offerRefund, label: "offer refund()")],
                outputs: [PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(o.fields.buyer)), label: "refund to the buyer")]
            )
            d.lockTime = UInt64(o.fields.refundAfter)
            if env.blockDaa <= UInt64(o.fields.refundAfter) {
                d.notes.append("not refundable yet: the virtual DAA must pass \(o.fields.refundAfter) (now \(env.blockDaa))")
            }
            return try finish(d, wallet: [], fee: .fromOutput(index: 0, cap: params.offerMaxFee), env: env)
        }

        // MARK: The exit

        private func exitChecks(_ x: ExitParts) throws {
            let key = x.name.fields.key
            guard x.below.hi == key, x.above.lo == key else { throw Failure("the gaps do not sit on \(x.name.name)") }
            try checkLive("lower gap", x.below.utxo, value: params.gapValue, covenant: registryId)
            try checkLive(x.name.name, x.name.utxo, value: params.bond, covenant: registryId)
            try checkLive("upper gap", x.above.utxo, value: params.gapValue, covenant: registryId)
        }

        /// The owner releases: [merge, release(sig), absorbed] -> [merged gap, bond + gap value - fee].
        func release(env: Env, parts x: ExitParts) throws -> Plan {
            try requireOwner(env, x.name)
            try exitChecks(x)
            var d = Draft(
                op: "release \(x.name.name)",
                inputs: [
                    try gapInput(x.below, "merge", [], role: .gapMerge, label: "gap merge"),
                    try nameInput(x.name, "release", [.signature], role: .nameRelease, label: "name release (owner sig)"),
                    try gapInput(x.above, "absorbed", [], role: .gapAbsorbed, label: "gap absorbed")
                ],
                outputs: [
                    PlannedOutput(output: gapOutput(lo: x.below.lo, hi: x.above.hi), label: "merged gap"),
                    PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(env.me)), label: "bond + freed gap value - fee")
                ]
            )
            d.payload = Codec.namePayload(op: "release", name: x.name.name)
            return try finish(d, wallet: [], fee: .fromOutput(index: 1, cap: nil), env: env)
        }

        /// Anyone reclaims a lapsed name: [merge, reclaim(), absorbed] -> [merged gap, the bond to
        /// the last owner, the caller's bounty]; lock time = expiresAt + grace (unix ms).
        func reclaim(env: Env, parts x: ExitParts) throws -> Plan {
            try exitChecks(x)
            let unlock = x.name.fields.expiresAt + params.graceMs
            guard unlock > 0, UInt64(unlock) >= lockTimeThreshold else { throw Failure("expiresAt + grace is not a timestamp") }
            var d = Draft(
                op: "reclaim \(x.name.name)",
                inputs: [
                    try gapInput(x.below, "merge", [], role: .gapMerge, label: "gap merge"),
                    try nameInput(x.name, "reclaim", [], role: .nameReclaim, label: "name reclaim()"),
                    try gapInput(x.above, "absorbed", [], role: .gapAbsorbed, label: "gap absorbed")
                ],
                outputs: [
                    PlannedOutput(output: gapOutput(lo: x.below.lo, hi: x.above.hi), label: "merged gap"),
                    PlannedOutput(output: TxOutput(value: params.bond, script: Codec.p2pkScript(x.name.fields.owner)), label: "bond to the last owner"),
                    PlannedOutput(output: TxOutput(value: 0, script: Codec.p2pkScript(env.me)), label: "bounty (caller)")
                ]
            )
            d.lockTime = UInt64(unlock)
            if Int64(env.blockTimeMs) <= unlock {
                d.notes.append("not reclaimable yet: the virtual median time must pass expiresAt + grace")
            }
            d.payload = Codec.namePayload(op: "reclaim", name: x.name.name)
            return try finish(d, wallet: [], fee: .fromOutput(index: 2, cap: nil), env: env)
        }
    }
}
