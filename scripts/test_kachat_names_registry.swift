import Foundation

// The .kachat registry data layer's pure part (KaChat/Services/KachatNames/KachatNamesRegistryState.swift):
// the walker's transition decoder against the kachat-domains vectors (every e2e transaction applied in
// order, every later step's records found in the walked state), the walk loop over a simulated chain,
// refusals, the status / label / profile rules, the REST transaction parser, and the indexer shapes.
// Run from the repo root with:
//
// swiftc -O -parse-as-library KaChat/Utilities/Blake3.swift KaChat/Services/Blake2b.swift KaChat/Utilities/Bech32.swift \
//   KaChat/Services/KachatNames/KachatNamesCodec.swift KaChat/Services/KachatNames/KachatNamesTransaction.swift \
//   KaChat/Services/KachatNames/KachatNamesManifest.swift KaChat/Services/KachatNames/KachatNamesBuilder.swift \
//   KaChat/Services/KachatNames/KachatNamesRegistryState.swift scripts/test_kachat_names_registry.swift \
//   -o /tmp/kachat_names_registry_test && /tmp/kachat_names_registry_test
//
// `/tmp/kachat_names_registry_test KaChatTests/KachatNamesVectors-v5.json` runs the same over the
// registry v5 vectors, which open with two imports from a migration snapshot.
//
// `/tmp/kachat_names_registry_test --live` also walks the LIVE testnet-10 registry from the bundled
// manifest, read-only, through api-tn10.kaspa.org (UTXO liveness from GET /addresses/{a}/utxos instead
// of a node, spends from GET /addresses/{a}/full-transactions), and prints what it found.

/// Bech32.swift's `KaspaAddress.fromPublicKey` takes the app's NetworkType.
enum NetworkType { case mainnet, testnet }

typealias KN = KachatNames
typealias J = [String: Any]

final class Report {
    var pass = 0
    var fail = 0
    var failures: [String] = []
    func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { pass += 1 } else { fail += 1; failures.append(what()) }
    }
    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { check(a == b, "\(what): got \(a) expected \(b)") }
}

func u64(_ v: Any?) -> UInt64 { (v as! NSNumber).uint64Value }
func i64(_ v: Any?) -> Int64 { (v as! NSNumber).int64Value }
func s(_ v: Any?) -> String { v as! String }
func hx(_ v: Any?) -> Data { try! KN.unhex(v as! String) }

/// A vector step's signed transaction, as the walker sees it.
func view(_ st: J, at: Int64) -> KN.TxView {
    let e = st["expected"] as! J
    return KN.TxView(
        id: hx(e["txid"]),
        inputs: (e["inputs"] as! [J]).map { KN.ViewInput(outpoint: KN.Outpoint(txid: hx($0["txid"]), index: UInt32(u64($0["index"]))), signatureScript: hx($0["signatureScript"])) },
        outputs: (e["outputs"] as! [J]).map { o in
            KN.TxOutput(value: u64(o["value"]), scriptVersion: UInt16(u64(o["scriptVersion"])), script: hx(o["script"]),
                        covenant: (o["covenant"] as? J).map { KN.CovenantBinding(authorizingInput: UInt16(u64($0["authorizingInput"])), covenantId: hx($0["covenantId"])) })
        },
        payload: hx(e["payload"]),
        at: at
    )
}

func outpointKey(_ u: J) -> String { "\(s(u["txid"])):\(u64(u["index"]))" }

/// The vectors' end-to-end plan (README "The end-to-end run", registry v3), after both geneses:
/// commits, three registrations, a price change, extend, renew, another price change, transfer,
/// list, buy, four offers (accept, decline, refund, withdraw), release, reclaim. The steps after
/// it are edge cases on their own synthetic records. Registry v5 vectors open with `lead` imports
/// from the migration snapshot (set from the vectors in `main`), then the same plan.
var lead = 0
var e2eCount: Int { 21 + lead }

/// Every record a step was built from must be in the walked state, exactly.
func checkRecords(_ st: J, _ state: KN.RegistryState, _ r: Report) {
    let label = s(st["label"])
    let rec = st["records"] as! J
    for k in ["gap", "below", "above"] {
        guard let g = rec[k] as? J else { continue }
        let u = g["utxo"] as! J
        let found = state.gaps.first { "\($0.txid):\($0.index)" == outpointKey(u) }
        r.check(found != nil, "\(label): \(k) gap \(outpointKey(u).prefix(16)) not in the walked state")
        if let f = found {
            r.eq(f.lo, s(g["lo"]), "\(label): \(k) lo")
            r.eq(f.hi, s(g["hi"]), "\(label): \(k) hi")
            r.eq(f.value, u64(g["value"]), "\(label): \(k) value")
        }
    }
    if let n = rec["name"] as? J {
        let u = n["utxo"] as! J
        let found = state.names.first { "\($0.txid):\($0.index)" == outpointKey(u) }
        r.check(found != nil, "\(label): name \(s(n["name"])) at \(outpointKey(u).prefix(16)) not in the walked state")
        if let f = found {
            r.eq(f.name, s(n["name"]), "\(label): name")
            r.eq(f.key, s(n["key"]), "\(label): key")
            r.eq(f.owner, s(n["owner"]), "\(label): owner")
            r.eq(f.price, i64(n["price"]), "\(label): price")
            r.eq(f.periodStart, i64(n["periodStart"]), "\(label): periodStart")
            r.eq(f.expiresAt, i64(n["expiresAt"]), "\(label): expiresAt")
            r.eq(f.value, u64(n["value"]), "\(label): value")
        }
    }
    if let o = rec["offer"] as? J {
        let u = o["utxo"] as! J
        let found = state.offers.first { "\($0.txid):\($0.index)" == outpointKey(u) }
        r.check(found != nil, "\(label): offer at \(outpointKey(u).prefix(16)) not in the walked state")
        if let f = found {
            r.eq(f.key, s(o["key"]), "\(label): offer key")
            r.eq(f.buyer, s(o["buyer"]), "\(label): offer buyer")
            r.eq(f.seller, s(o["seller"]), "\(label): offer seller")
            r.eq(f.refundAfter, i64(o["refundAfter"]), "\(label): offer refundAfter")
            r.eq(f.value, u64(o["value"]), "\(label): offer value")
        }
    }
}

/// A state holding exactly a step's records (the edge cases run on synthetic registry UTXOs).
func seeded(_ st: J, _ m: KN.Manifest) -> KN.RegistryState {
    var state = KN.RegistryState.atGenesis(m)
    state.gaps = []
    state.applied = []
    let rec = st["records"] as! J
    for k in ["gap", "below", "above"] {
        guard let g = rec[k] as? J else { continue }
        let u = g["utxo"] as! J
        state.gaps.append(.init(txid: s(u["txid"]), index: UInt32(u64(u["index"])), lo: s(g["lo"]), hi: s(g["hi"]), value: u64(g["value"])))
    }
    if let n = rec["name"] as? J {
        let u = n["utxo"] as! J
        state.names.append(.init(txid: s(u["txid"]), index: UInt32(u64(u["index"])), name: s(n["name"]), key: s(n["key"]), owner: s(n["owner"]),
                                 price: i64(n["price"]), periodStart: i64(n["periodStart"]), expiresAt: i64(n["expiresAt"]), value: u64(n["value"])))
    }
    if let o = rec["offer"] as? J {
        let u = o["utxo"] as! J
        state.offers.append(.init(txid: s(u["txid"]), index: UInt32(u64(u["index"])), key: s(o["key"]), buyer: s(o["buyer"]),
                                  seller: s(o["seller"]), refundAfter: i64(o["refundAfter"]), value: u64(o["value"]), name: o["name"] as? String))
    }
    return state
}

func runWalker(_ v: J, _ r: Report) {
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let steps = v["steps"] as! [J]
    let e2e = Array(steps.prefix(e2eCount))
    var state = KN.RegistryState.atGenesis(m)
    var ops: [String] = []
    for (i, st) in e2e.enumerated() {
        checkRecords(st, state, r)
        do {
            let events = try state.apply(view(st, at: Int64(1_000 + i)), manifest: m)
            ops.append(contentsOf: events.map { "\($0.op) \($0.name ?? "?")" })
        } catch {
            r.check(false, "\(s(st["label"])): apply threw \(error)")
        }
        do { try state.checkInvariants() } catch { r.check(false, "\(s(st["label"])): invariants: \(error)") }
    }
    let imported = e2e.prefix(lead).map { String(s($0["label"]).dropFirst("import ".count)) }
    r.eq(ops, imported.map { "import \($0)" } + [
        "register alpha-tn", "register bravo-tn", "register lapse-tn", "extend alpha-tn", "renew lapse-tn",
        "transfer alpha-tn", "list alpha-tn", "sale alpha-tn", "offer bravo-tn", "offer_accepted bravo-tn", "offer_accept bravo-tn",
        "offer alpha-tn", "offer_decline alpha-tn", "offer alpha-tn", "offer_refund alpha-tn",
        "offer alpha-tn", "offer_withdraw alpha-tn", "release bravo-tn", "reclaim lapse-tn"
    ], "e2e events")
    r.eq(state.names.map(\.name).sorted(), (imported + ["alpha-tn"]).sorted(), "names left after the e2e plan")
    r.eq(state.gaps.count, 2 + lead, "gaps left after the e2e plan")
    if lead > 0, let rules = v["migrationRules"] as? J, let snap = rules["snapshot"] as? J, let entries = snap["entries"] as? [J] {
        // registry v5: each import is the snapshot entry exactly - owner, paid period - and unlisted
        r.eq(entries.count, lead, "v5: one import per snapshot entry")
        for e in entries {
            let n = state.name(s(e["name"]))
            r.eq(n?.owner, s(e["owner"]), "v5 import \(s(e["name"])): owner")
            r.eq(n?.periodStart, i64(e["periodStart"]), "v5 import \(s(e["name"])): periodStart")
            r.eq(n?.expiresAt, i64(e["expiresAt"]), "v5 import \(s(e["name"])): expiresAt")
            r.eq(n?.price, 0, "v5 import \(s(e["name"])): unlisted")
            r.eq(n?.key, s(e["key"]), "v5 import \(s(e["name"])): key")
        }
        // the same import on a v4 manifest is refused
        var v4 = v["manifest"] as! J
        v4["registryVersion"] = 4
        var p4 = v4["params"] as! J
        p4.removeValue(forKey: "migration")
        v4["params"] = p4
        if let m4 = try? KN.Manifest.decode(JSONSerialization.data(withJSONObject: v4)) {
            var st4 = KN.RegistryState.atGenesis(m4)
            r.check((try? st4.apply(view(e2e[0], at: 1_000), manifest: m4)) == nil, "v5: an import is refused on a v4 manifest")
        }
    }
    r.eq(state.offers.count, 0, "offers left after the e2e plan")
    let accepted = state.events.first { $0.op == "offer_accepted" }
    r.check((accepted?.price ?? 0) > 9 * 100_000_000 && (accepted?.price ?? 0) < 10 * 100_000_000, "accepted offer payout is the offer less the fee")
    let alpha = state.name("alpha-tn")
    r.check(alpha?.registeredTxId == KN.hex(hx((e2e[lead + 3]["expected"] as! J)["txid"])), "registration tx carried through every transition")
    r.eq(alpha?.registeredAt, Int64(1_003 + lead), "registration time carried through every transition")
    let alphaRegister = (e2e[lead + 3]["args"] as! J)
    r.eq(alpha?.periodStart, i64(alphaRegister["now"]), "alpha-tn: periodStart = register's now, kept by extend, transfer, list and buy")
    r.eq(alpha?.expiresAt, i64(alphaRegister["now"]) + 2 * m.params.periodMs, "alpha-tn: registered for 1 period, extended by 1")
    r.eq(m.params.periodMs, m.network == "mainnet" ? 31_536_000_000 : 86_400_000, "the vectors run their network's clock")
    // applying again changes nothing
    let snapshot = state
    for (i, st) in e2e.enumerated() { _ = try? state.apply(view(st, at: Int64(1_000 + i)), manifest: m) }
    r.eq(state, snapshot, "re-applying is a no-op")

    // the edge cases, each on a state seeded with its own records
    for st in steps.dropFirst(e2eCount) {
        var seededState = seeded(st, m)
        let label = s(st["label"])
        let before = ((st["records"] as! J)["name"] as? J).map { (periodStart: i64($0["periodStart"]), expiresAt: i64($0["expiresAt"])) }
        do {
            let events = try seededState.apply(view(st, at: 5), manifest: m)
            let op = s(st["op"])
            if op == "commit" || op == "cancelCommit" { r.check(events.isEmpty, "\(label): not a registry transaction") } else { r.check(!events.isEmpty, "\(label): no events") }
            switch op {
            case "register":
                r.eq(seededState.names.count, 1, "\(label): name created"); r.eq(seededState.gaps.count, 2, "\(label): gaps split")
            case "reclaim": r.eq(seededState.names.count, 0, "\(label): name gone"); r.eq(seededState.gaps.count, 1, "\(label): gaps merged")
            case "acceptOffer", "declineOffer": r.eq(seededState.offers.count, 0, "\(label): offer gone")
            case "extend", "renew":
                let years = i64((st["args"] as! J)["years"])
                let after = seededState.names.first
                r.eq(events.first?.op, op, "\(label): event")
                r.eq(events.first?.years, years, "\(label): event years")
                r.eq(after?.expiresAt, before.map { $0.expiresAt + years * m.params.periodMs }, "\(label): expiresAt + periods")
                // extend keeps the period; renew starts the next one at the old expiry
                r.eq(after?.periodStart, op == "extend" ? before?.periodStart : before?.expiresAt, "\(label): periodStart")
            default: break
            }
            if op == "acceptOffer" {
                let o = (st["records"] as! J)["offer"] as! J
                r.eq(seededState.names.first?.owner, s(o["buyer"]), "\(label): the name went to the buyer")
            }
        } catch {
            r.check(false, "\(label): apply threw \(error)")
        }
    }

    // refusals leave the state alone (on the first spend of the genesis gap: the first
    // registration, or on v5 the first import)
    let reg = steps[lead > 0 ? 0 : 3]
    var tampered = view(reg, at: 1)
    tampered.outputs[2].script[5] ^= 0x01
    var st0 = KN.RegistryState.atGenesis(m)
    r.check((try? st0.apply(tampered, manifest: m)) == nil, "a register whose name output holds another state was accepted")
    r.eq(st0, KN.RegistryState.atGenesis(m), "refused register left the state alone")
    var extra = view(reg, at: 1)
    extra.outputs.append(extra.outputs[0])
    r.check((try? st0.apply(extra, manifest: m)) == nil, "an unexplained registry output was accepted")
    var wrongAuth = view(reg, at: 1)
    wrongAuth.outputs[0].covenant?.authorizingInput = 1
    r.check((try? st0.apply(wrongAuth, manifest: m)) == nil, "an output authorized by another input was accepted")
    var badRedeem = view(reg, at: 1)
    var pushes = try! KN.Codec.parsePushes(badRedeem.inputs[0].signatureScript)
    var redeem = pushes.removeLast()
    redeem[redeem.count - 1] ^= 0x01
    badRedeem.inputs[0].signatureScript = pushes.map { KN.Codec.pushData($0) }.reduce(Data(), +) + KN.Codec.pushData(redeem)
    r.check((try? st0.apply(badRedeem, manifest: m)) == nil, "a spend revealing another redeem script was accepted")
    r.eq(st0, KN.RegistryState.atGenesis(m), "refusals left the state alone")
    // an unrelated transaction is ignored
    r.eq((try? st0.apply(view(steps[lead], at: 1), manifest: m))?.count, 0, "a commit is not a registry transaction")
}

/// The walk loop over a simulated chain holding every e2e transaction: liveness from the
/// simulated UTXO set, spends found through addresses, transactions handed back newest first.
func runWalk(_ v: J, _ r: Report) async {
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let steps = Array((v["steps"] as! [J]).prefix(e2eCount))
    let txs = steps.enumerated().map { view($0.element, at: Int64(1_000 + $0.offset)) }
    var created: [String: Data] = [:]       // outpoint -> script
    var spentBy: [String: String] = [:]     // outpoint -> txid
    for t in txs {
        for (k, o) in t.outputs.enumerated() { created["\(t.idHex):\(k)"] = o.script }
        for i in t.inputs { spentBy["\(KN.hex(i.outpoint.txid)):\(i.outpoint.index)"] = t.idHex }
    }
    // the genesis gap lives at the manifest's genesis outpoint
    created["\(KN.hex(m.genesisTxid)):0"] = m.genesisOutput.script
    func addr(_ script: Data) -> String? { KaspaAddress.address(fromScriptPublicKey: script, hrp: "kaspatest") }
    var expected = KN.RegistryState.atGenesis(m)
    for t in txs { _ = try? expected.apply(t, manifest: m) }

    for upTo in (lead > 0 ? [lead] : []) + [3, 6, 7, 8, 10, 11, 17].map({ $0 + lead }) + [e2eCount] {
        let visible = Array(txs.prefix(upTo))
        let visibleIds = Set(visible.map(\.idHex))
        var walked = KN.RegistryState.atGenesis(m)
        do {
            let report = try await walked.walk(
                manifest: m,
                address: addr,
                live: { addresses in
                    Set(created.filter { op, script in
                        addresses.contains(addr(script) ?? "")
                            && (op.hasPrefix(KN.hex(m.genesisTxid)) || visibleIds.contains(String(op.prefix(64))))
                            && !(spentBy[op].map { visibleIds.contains($0) } ?? false)
                    }.keys)
                },
                transactions: { a, _ in
                    visible.reversed().filter { t in
                        t.outputs.contains { addr($0.script) == a } || t.inputs.contains { i in created["\(KN.hex(i.outpoint.txid)):\(i.outpoint.index)"].flatMap(addr) == a }
                    }
                }
            )
            var reference = KN.RegistryState.atGenesis(m)
            for t in visible { _ = try? reference.apply(t, manifest: m) }
            r.eq(Set(walked.gaps.map { "\($0.txid):\($0.index)" }), Set(reference.gaps.map { "\($0.txid):\($0.index)" }), "walk to \(upTo): gaps")
            r.eq(walked.names.map(\.name).sorted(), reference.names.map(\.name).sorted(), "walk to \(upTo): names")
            r.eq(Set(walked.names.map { "\($0.txid):\($0.index)" }), Set(reference.names.map { "\($0.txid):\($0.index)" }), "walk to \(upTo): name outpoints")
            r.eq(Set(walked.offers.map { "\($0.txid):\($0.index)" }), Set(reference.offers.map { "\($0.txid):\($0.index)" }), "walk to \(upTo): offers")
            r.check(report.unresolved.isEmpty, "walk to \(upTo): unresolved \(report.unresolved)")
            do { try walked.checkInvariants() } catch { r.check(false, "walk to \(upTo): invariants \(error)") }
        } catch {
            r.check(false, "walk to \(upTo) threw \(error)")
        }
    }
    _ = expected
}

/// The walk must reach the same registry whatever order the REST API hands transactions back
/// in, with or without times, in one walk or several. A reclaim is found through its long-tracked
/// gaps in the same round as the renewal that precedes it: walked in the wrong order, the old
/// code merged the gaps, kept the reclaimed name and re-added it (report from the desktop port,
/// 2026-10-07).
func runWalkOrders(_ v: J, _ r: Report) async {
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let steps = Array((v["steps"] as! [J]).prefix(e2eCount))
    let timed = steps.enumerated().map { view($0.element, at: Int64(1_000 + $0.offset)) }
    var created: [String: Data] = [:]
    var spentBy: [String: String] = [:]
    for t in timed {
        for (k, o) in t.outputs.enumerated() { created["\(t.idHex):\(k)"] = o.script }
        for i in t.inputs { spentBy["\(KN.hex(i.outpoint.txid)):\(i.outpoint.index)"] = t.idHex }
    }
    created["\(KN.hex(m.genesisTxid)):0"] = m.genesisOutput.script
    func addr(_ script: Data) -> String? { KaspaAddress.address(fromScriptPublicKey: script, hrp: "kaspatest") }
    var reference = KN.RegistryState.atGenesis(m)
    for t in timed { _ = try? reference.apply(t, manifest: m) }

    func walk(_ state: inout KN.RegistryState, upTo: Int, order: ([KN.TxView]) -> [KN.TxView], times: Bool) async throws -> KN.RegistryState.WalkReport {
        let visible = Array(timed.prefix(upTo)).map { t -> KN.TxView in var c = t; if !times { c.at = nil }; return c }
        let visibleIds = Set(visible.map(\.idHex))
        return try await state.walk(
            manifest: m, address: addr,
            live: { addresses in
                Set(created.filter { op, script in
                    addresses.contains(addr(script) ?? "")
                        && (op.hasPrefix(KN.hex(m.genesisTxid)) || visibleIds.contains(String(op.prefix(64))))
                        && !(spentBy[op].map { visibleIds.contains($0) } ?? false)
                }.keys)
            },
            transactions: { a, _ in
                order(visible.filter { t in
                    t.outputs.contains { addr($0.script) == a } || t.inputs.contains { i in created["\(KN.hex(i.outpoint.txid)):\(i.outpoint.index)"].flatMap(addr) == a }
                })
            }
        )
    }
    func same(_ s: KN.RegistryState, _ label: String) {
        r.eq(Set(s.gaps.map { "\($0.txid):\($0.index)" }), Set(reference.gaps.map { "\($0.txid):\($0.index)" }), "\(label): gaps")
        r.eq(Set(s.names.map { "\($0.name)@\($0.txid):\($0.index)" }), Set(reference.names.map { "\($0.name)@\($0.txid):\($0.index)" }), "\(label): names")
        r.eq(Set(s.offers.map { "\($0.txid):\($0.index)" }), Set(reference.offers.map { "\($0.txid):\($0.index)" }), "\(label): offers")
        // a walk can't discover offers (no registry UTXO marks them), so their events are left out
        func nameEvents(_ e: [KN.Event]) -> [String] {
            e.map(\.op).filter { $0 == "offer_accepted" || !$0.hasPrefix("offer") }.sorted()
        }
        r.eq(nameEvents(s.events), nameEvents(reference.events), "\(label): events")
        r.check((try? s.checkInvariants()) != nil, "\(label): invariants")
    }
    // a fixed shuffle, so a failure reproduces
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func shuffled(_ a: [KN.TxView]) -> [KN.TxView] {
        var out = a
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            out.swapAt(i, Int(seed >> 33) % (i + 1))
        }
        return out
    }
    let orders: [(String, ([KN.TxView]) -> [KN.TxView])] = [
        ("newest first", { $0.reversed() }), ("oldest first", { $0 }), ("shuffled", shuffled), ("by id", { $0.sorted { $0.idHex < $1.idHex } })
    ]
    for (name, order) in orders {
        for times in [true, false] {
            let label = "walk \(name)\(times ? "" : ", no times")"
            var s = KN.RegistryState.atGenesis(m)
            do {
                let report = try await walk(&s, upTo: e2eCount, order: order, times: times)
                r.check(!report.stale, "\(label): stale")
                r.check(report.rounds < 30, "\(label): \(report.rounds) rounds")
                same(s, label)
            } catch {
                r.check(false, "\(label) threw \(error)")
            }
            // and incrementally, a few transactions visible at a time
            var inc = KN.RegistryState.atGenesis(m)
            do {
                for upTo in [4, 7, 9, 13, 18].map({ $0 + lead }) + [e2eCount] { _ = try await walk(&inc, upTo: upTo, order: order, times: times) }
                same(inc, "\(label), incremental")
            } catch {
                r.check(false, "\(label), incremental threw \(error)")
            }
        }
    }
    // The live case: the gaps a reclaim spends are tracked, but the name only at an earlier
    // version (its renewal hasn't been walked yet). The reclaim must wait, changing nothing -
    // applied, it would merge the gaps and keep the name, which the renewal later re-adds.
    if let reclaimIdx = steps.firstIndex(where: { s($0["op"]) == "reclaim" }),
       let renewIdx = steps.firstIndex(where: { s($0["op"]) == "renew" }) {
        var st = KN.RegistryState.atGenesis(m)
        for t in timed.prefix(reclaimIdx) { _ = try? st.apply(t, manifest: m) }
        let renew = timed[renewIdx]
        let oldName = (steps[renewIdx]["records"] as! J)["name"] as! J
        guard let k = st.names.firstIndex(where: { $0.name == s(oldName["name"]) }), let prev = renew.inputs.first?.outpoint else {
            r.check(false, "no renewed name to roll back"); return
        }
        st.names[k].txid = KN.hex(prev.txid)
        st.names[k].index = prev.index
        st.names[k].periodStart = i64(oldName["periodStart"])
        st.names[k].expiresAt = i64(oldName["expiresAt"])
        let before = st
        do {
            _ = try st.apply(timed[reclaimIdx], manifest: m)
            r.check(false, "a reclaim of an untracked name version was applied")
        } catch {
            r.eq(error as? KN.Failure, KN.Failure.waitsForEarlierTransaction, "the early reclaim waits")
        }
        r.eq(st, before, "the waiting reclaim changed nothing")
        r.check(st.names.contains { $0.name == s(oldName["name"]) }, "the name is still there to be renewed, then reclaimed")
    } else {
        r.check(false, "no reclaim / renew in the vectors")
    }
    // a stale UTXO (a tracked output whose spender was already applied) is reported, not looped on
    // (the genesis gap, put back although the first registration - already applied - spent it)
    var stale = reference
    if let g = KN.RegistryState.atGenesis(m).gaps.first {
        stale.gaps.append(g)
        do {
            let report = try await walk(&stale, upTo: e2eCount, order: { $0 }, times: true)
            r.check(report.stale, "a stale tracked UTXO is reported")
            r.check(report.rounds <= 2, "stale: \(report.rounds) rounds")
        } catch {
            r.check(false, "stale walk threw \(error)")
        }
    }
}

func runRules(_ r: Report) {
    let g: Int64 = 864_000_000
    r.eq(KN.Status.of(expiresAt: 1_000, graceMs: g, nowMs: 999), .active, "status before expiry")
    r.eq(KN.Status.of(expiresAt: 1_000, graceMs: g, nowMs: 1_000), .grace, "status at expiry")
    r.eq(KN.Status.of(expiresAt: 1_000, graceMs: g, nowMs: 1_000 + g - 1), .grace, "status in grace")
    r.eq(KN.Status.of(expiresAt: 1_000, graceMs: g, nowMs: 1_000 + g), .lapsed, "status at grace end")
    let me = Data(repeating: 7, count: 32)
    func info(_ n: String, exp: Int64, reg: Int64?) -> KN.NameInfo {
        KN.NameInfo(name: n, key: KN.Codec.key(n), owner: me, price: 0, expiresAt: exp, outpoint: KN.Outpoint(txid: KN.zero32, index: 0), registeredAt: reg)
    }
    let now: Int64 = 10_000_000_000_000
    // "grace" expired but is in its grace period; "gone" lapsed (back on the market). A name in
    // grace still labels its owner (2026-10-07); only a lapsed one doesn't.
    let owned = [info("zeta", exp: now + 5, reg: 10), info("alpha", exp: now + 5, reg: 20),
                 info("grace", exp: now - 5, reg: 5), info("gone", exp: now - g - 5, reg: 1)]
    r.eq(KN.label(owned: owned, primaryName: nil, graceMs: g, nowMs: now), "grace", "label: the oldest held name (one in grace counts)")
    r.eq(KN.label(owned: owned, primaryName: "Alpha.kachat", graceMs: g, nowMs: now), "alpha", "label: the primary name")
    r.eq(KN.label(owned: owned, primaryName: "grace", graceMs: g, nowMs: now), "grace", "label: a primary name in grace still labels")
    r.eq(KN.label(owned: owned, primaryName: "gone", graceMs: g, nowMs: now), "grace", "label: a lapsed primary name is skipped")
    r.eq(KN.label(owned: owned, primaryName: "notmine", graceMs: g, nowMs: now), "grace", "label: a primary name not owned is skipped")
    r.eq(KN.label(owned: [owned[0], owned[1]], primaryName: nil, graceMs: g, nowMs: now), "zeta", "label: the oldest active name")
    r.eq(KN.label(owned: [owned[3]], primaryName: nil, graceMs: g, nowMs: now), nil, "label: only a lapsed name")

    var p = KN.Profile()
    p.avatar = " x.com/KaspaCurrency/ "
    p.banner = "youtube.com/@KaspaCurrency"
    p.bio = "instagram.com/instagram"
    p.linktree = "https://www.linktr.ee/kaspa?utm=1"
    p.primaryName = "Alice.kachat"
    let clean = p.sanitized()
    r.eq(clean.avatar, "https://x.com/KaspaCurrency", "profile: avatar source normalized")
    r.eq(clean.banner, "https://www.youtube.com/@KaspaCurrency", "profile: banner from another account")
    r.eq(clean.bio, nil, "profile: a bio source on a platform without bios is dropped")
    r.eq(clean.linktree, "https://linktr.ee/kaspa", "profile: Linktree link normalized")
    r.eq(clean.primaryName, "alice", "profile: primary name normalized")
    var other = KN.Profile()
    other.avatar = "https://example.com/me"
    other.banner = "instagram.com/instagram"
    other.linktree = "https://example.com/links"
    r.eq(other.sanitized(), KN.Profile(), "profile: unsupported social site and non-Linktree link dropped")
    let json = try! p.recordJSON()
    r.check(json.count <= 2048, "profile JSON within 2 KB")
    r.eq(String(data: json, encoding: .utf8)!, "{\"avatar\":\"https://x.com/KaspaCurrency\",\"banner\":\"https://www.youtube.com/@KaspaCurrency\",\"linktree\":\"https://linktr.ee/kaspa\",\"primaryName\":\"alice\",\"v\":1}", "profile JSON compact with sorted keys")
    r.eq(KN.Profile.parse(json), clean, "profile JSON round trip")
    r.eq(KN.Profile.parse(Data("{\"v\":1,\"displayName\":\"x\",\"bio\":\"free text\",\"avatar\":\"ftp://a\"}".utf8)), KN.Profile(), "profile: free text, display names and bad links dropped")
    r.eq(KN.Profile.parse(Data("{\"v\":2}".utf8)), nil, "profile: only v 1")

    // what a social link shows
    typealias SS = KN.SocialSource
    r.eq(SS.decodeEntities("a &amp; b &#39;c&#x27; &#064;d &quot;e&quot; &amp;#39;"), "a & b 'c' @d \"e\" &#39;", "entities decoded one level")
    let html = "<meta property=\"og:image\" content=\"https://pbs.twimg.com/profile_images/1/a_200x200.jpg\"/><meta property=\"og:description\" content=\"Builder &amp; miner\"/>"
    r.eq(SS.openGraphImage(in: html).map(SS.xAvatar), "https://pbs.twimg.com/profile_images/1/a_400x400.jpg", "X avatar upgraded to 400px")
    r.eq(SS.bio(for: .x, openGraphDescription: SS.openGraphDescription(in: html)), "Builder & miner", "X bio from og:description")
    r.eq(SS.bio(for: .twitch, openGraphDescription: "Speedruns — Twitch streams live on Twitch!"), "Speedruns", "Twitch boilerplate cut")
    r.eq(SS.bio(for: .instagram, openGraphDescription: "687M Followers, 305 Following"), nil, "no bio from Instagram's counts")
    r.eq(SS.bio(for: .x, openGraphDescription: String(repeating: "b", count: 400))?.count, 280, "bio cut to 280")
    let gh = SS.githubProfile(fromJSON: Data("{\"avatar_url\":\"https://avatars.githubusercontent.com/u/1\",\"bio\":\" hi \"}".utf8))
    r.check(gh.avatar == "https://avatars.githubusercontent.com/u/1" && gh.bio == "hi", "GitHub avatar and bio")
    let fx = SS.fxTwitterProfile(fromJSON: Data("{\"code\":200,\"user\":{\"avatar_url\":\"https://pbs.twimg.com/profile_images/1/a_normal.jpg\",\"banner_url\":\"https://pbs.twimg.com/profile_banners/9/8\",\"description\":\"hi\"}}".utf8))
    r.eq(fx, KN.SocialProfile(avatar: "https://pbs.twimg.com/profile_images/1/a_400x400.jpg", banner: "https://pbs.twimg.com/profile_banners/9/8/1500x500", bio: "hi"), "FxTwitter: avatar 400px, banner 1500x500, bio")
    r.eq(SS.fxTwitterProfile(fromJSON: Data("{\"code\":404,\"message\":\"NOT_FOUND\"}".utf8)), KN.SocialProfile(), "FxTwitter: unknown account answers empty")
    r.eq(SS.fxTwitterProfile(fromJSON: Data("{\"code\":500}".utf8)), nil, "FxTwitter: an error means fall back")
    r.eq(SS(link: "instagram.com/instagram", for: .bio), nil, "no bio source on Instagram")
    r.eq(SS.from(platform: .x, handle: "@KaspaCurrency", for: .avatar)?.link, "https://x.com/KaspaCurrency", "X handle with @")
    r.eq(SS.from(platform: .youtube, handle: "MrBeast", for: .banner)?.link, "https://www.youtube.com/@MrBeast", "YouTube handle")
    r.eq(SS.from(platform: .tiktok, handle: "tiktok", for: .avatar)?.link, "https://www.tiktok.com/@tiktok", "TikTok handle")
    r.eq(SS.from(platform: .linkedin, handle: "company/linkedin", for: .avatar)?.link, "https://www.linkedin.com/company/linkedin", "LinkedIn company path")
    r.eq(SS.from(platform: .discord, handle: "discord-developers", for: .bio)?.link, "https://discord.gg/discord-developers", "Discord invite code")
    let pasted = SS.from(platform: .x, handle: "https://www.youtube.com/@MrBeast", for: .avatar)
    r.check(pasted?.platform == .youtube && pasted?.displayHandle == "MrBeast", "a pasted link switches platform")
    r.eq(SS.from(platform: .instagram, handle: "instagram", for: .banner), nil, "no banner from Instagram")
    r.eq(SS.from(platform: .x, handle: "bad handle!", for: .avatar), nil, "invalid handle refused")
    r.eq(KN.Profile.linktreeLink(username: "kaspa"), "https://linktr.ee/kaspa", "Linktree from a username")
    r.eq(KN.Profile.linktreeLink(username: "@kaspa "), "https://linktr.ee/kaspa", "Linktree from @username")
    r.eq(KN.Profile.linktreeLink(username: "https://linktr.ee/kaspa"), "https://linktr.ee/kaspa", "Linktree from a pasted link")
    r.eq(KN.Profile.linktreeLink(username: "kas pa"), nil, "Linktree username with a space refused")
    r.eq(KN.Profile.linktreeUsername("https://linktr.ee/kaspa"), "kaspa", "Linktree username shown back")
    r.check(SS(link: "t.me/telegram", for: .bio) != nil, "bio source on Telegram")
    r.eq(SS.discordDescription(fromInviteJSON: Data("{\"guild\":{\"id\":\"1\",\"description\":\"Devs\"}}".utf8)), "Devs", "Discord server description")

    // the paid period on a NameInfo (mainnet's clock: a year, a 10-day window)
    let params = KN.Params(bond: 1, gapValue: 1, tCommit: 600, maxYears: 2, periodMs: KN.yearMs, graceMs: g, renewWindowMs: 864_000_000,
                           registerPrices: [1, 1, 1, 1, 1], renewPrices: [1, 1, 1, 1, 1], offerMaxFee: 1)
    var period = info("period", exp: now + KN.yearMs, reg: 1)
    r.eq(period.extendableYears(params), 0, "period unknown: no extend")
    r.eq(period.fields, nil, "period unknown: no on-chain state")
    period.periodStart = now
    r.eq(period.extendableYears(params), 1, "1 year paid of 2: extend by 1")
    r.eq(period.fields?.periodStart, now, "fields carry periodStart")
    r.check(!period.renewOpen(params, nowMs: now), "renewal closed a year before expiry")
    r.eq(period.renewOpens(params), now + KN.yearMs - 864_000_000, "renewal opens 10 days before expiry")
    r.check(period.renewOpen(params, nowMs: now + KN.yearMs - 864_000_000), "renewal open at the opening")
    period.expiresAt = now + 2 * KN.yearMs
    r.eq(period.extendableYears(params), 0, "2 years paid: no extend")
    // testnet's 10-minute clock
    let tn = KN.Params(bond: 1, gapValue: 1, tCommit: 600, maxYears: 2, periodMs: 600_000, graceMs: 600_000, renewWindowMs: 600_000,
                       registerPrices: [1, 1, 1, 1, 1], renewPrices: [1, 1, 1, 1, 1], offerMaxFee: 1)
    var short = info("short", exp: now + 600_000, reg: 1)
    short.periodStart = now
    r.eq(short.extendableYears(tn), 1, "10 min paid of 20: extend by 1")
    r.check(short.renewOpen(tn, nowMs: now), "a 1-period name's window is open at once on the short clock")
    short.expiresAt = now + 1_200_000
    r.eq(short.extendableYears(tn), 0, "20 min paid: no extend")
    r.check(!short.renewOpen(tn, nowMs: now), "renewal closed 20 min before expiry")

    // offers: declined once the name has another owner
    let seller = Data(repeating: 3, count: 32)
    let offer = KN.OfferInfo(outpoint: KN.Outpoint(txid: KN.zero32, index: 0), key: KN.Codec.key("x"), name: "x", buyer: me, seller: seller,
                             amount: 5, refundAfter: 100, createdAt: nil)
    r.check(!offer.isDeclined(currentOwner: seller), "an offer to the current owner stands")
    r.check(offer.isDeclined(currentOwner: me), "an offer to an earlier owner is declined")
    r.eq(offer.fields.seller, seller, "offer fields carry the seller")

    // a cache written before registry v4 (format 1 - 3) is dropped
    let v1Cache = Data("""
    {"version":1,"network":"testnet-10","registryCovenantId":"00","gaps":[],"names":[{"txid":"00","index":0,"name":"a","key":"00","owner":"00","price":0,"expiresAt":1,"value":1}],"offers":[],"applied":[],"events":[]}
    """.utf8)
    r.check((try? JSONDecoder().decode(KN.RegistryState.self, from: v1Cache)) == nil, "a registry v1 cache does not decode")
    let v2Cache = Data("""
    {"version":2,"network":"testnet-10","registryCovenantId":"00","gaps":[],"names":[],"offers":[],"applied":[],"events":[]}
    """.utf8)
    // (v4's fields are v2's again, so it may decode - its version keeps it from being used)
    r.check((try? JSONDecoder().decode(KN.RegistryState.self, from: v2Cache))?.version != KN.RegistryState.formatVersion, "a registry v2 cache is not current")
    let v3Cache = Data("""
    {"version":3,"network":"testnet-10","registryCovenantId":"00","priceCovenantId":"00","shards":[],"gaps":[],"names":[],"offers":[],"applied":[],"events":[]}
    """.utf8)
    r.check((try? JSONDecoder().decode(KN.RegistryState.self, from: v3Cache))?.version != KN.RegistryState.formatVersion, "a registry v3 cache is not current")
    r.eq(KN.RegistryState.formatVersion, 4, "cache format 4 (registry v4)")

    let k = Data(repeating: 0x10, count: 31) + Data([0x00])
    r.eq(KN.step(k, by: -1).map(KN.hex), KN.hex(Data(repeating: 0x10, count: 30) + Data([0x0f, 0xff])), "key - 1 borrows")
    r.eq(KN.step(k, by: 1).map(KN.hex), KN.hex(Data(repeating: 0x10, count: 31) + Data([0x01])), "key + 1")
    r.eq(KN.step(KN.zero32, by: -1), nil, "0 - 1")
    r.eq(KN.step(KN.ff32, by: 1), nil, "ff..ff + 1")
}

/// The REST API's shape for a version-1 transaction (the live genesis, 2026-10-02).
let genesisREST = """
{"subnetwork_id":"0000000000000000000000000000000000000000","transaction_id":"cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f","hash":"7a9e06cd3134a0cf0d90ecfb21d953a3ab3740f36fa00c552c2c3d10e8097978","mass":"2083","payload":null,"block_hash":["67c7ad399972fa99598c3baccfb380a89c509d5634d3738ed3bbca0e344162d4"],"block_time":1790909722843,"version":1,"is_accepted":true,"accepting_block_hash":"f6f3e6b5831b88991fe6bf47b7170fa6f0699126c217cf9f11236faed4d1b41d","accepting_block_blue_score":574239955,"accepting_block_time":1790909722989,"inputs":[{"transaction_id":"cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f","index":0,"previous_outpoint_hash":"f12c99e6f39833515eccb9900d5b8596565751dd76cbac98374597d9fbe73dab","previous_outpoint_index":"0","previous_outpoint_address":null,"previous_outpoint_amount":null,"signature_script":"41f5af0ec9cbad01185cfb488ceed108470a40af4d488ffe00da825ab0e9f5c65469e5dd1b60e18a6d66e611300a4d6965af730ead2b404841c5090f0a520aa91401","sig_op_count":null,"compute_budget":10,"covenant_id":null}],"outputs":[{"transaction_id":"cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f","index":0,"amount":100000000,"script_public_key":"aa2091e1c42572eec31a4bdfab6f4fe298fe51cb0934ac6f2cdb87e1052082744cc987","script_public_key_address":"kaspatest:pzg7r3p9wthvxxjtm74k7nlznrl9rjcfxjkx7txmslss2gyzw3xvj686vxecj","script_public_key_type":"scripthash","covenant_authorizing_input":0,"covenant_id":"9444187f09a3e77450e125d448b21eb79b3c54b692a5b3f3e8af38343b9a7a51"},{"transaction_id":"cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f","index":1,"amount":99791700,"script_public_key":"20a866cf597e3e681324adbc115ec34ca7746813cf70f6bfe4f9c36f2c9dd30848ac","script_public_key_address":"kaspatest:qz5xdn6e0clxsyey4k7pzhkrfjnhg6qneac0d0lyl8pk7tya6vyysf8pt3r8m","script_public_key_type":"pubkey","covenant_authorizing_input":null,"covenant_id":null}]}
"""

func runREST(_ r: Report) {
    let j = try! JSONSerialization.jsonObject(with: Data(genesisREST.utf8)) as! J
    guard let t = try! KN.TxView.fromREST(j) else { r.check(false, "REST genesis parsed as not accepted"); return }
    r.eq(t.idHex, "cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f", "REST txid")
    r.eq(t.inputs.count, 1, "REST inputs")
    r.eq(KN.hex(t.inputs[0].outpoint.txid), "f12c99e6f39833515eccb9900d5b8596565751dd76cbac98374597d9fbe73dab", "REST input outpoint")
    r.eq(t.outputs.count, 2, "REST outputs")
    r.eq(t.outputs[0].covenant?.authorizingInput, 0, "REST covenant binding")
    r.eq(t.outputs[0].covenant.map { KN.hex($0.covenantId) }, "9444187f09a3e77450e125d448b21eb79b3c54b692a5b3f3e8af38343b9a7a51", "REST covenant id")
    r.eq(t.outputs[1].covenant, nil, "REST plain output")
    r.eq(t.at, 1790909722989, "REST acceptance time")
    r.eq(KaspaAddress.address(fromScriptPublicKey: t.outputs[0].script, hrp: "kaspatest"), "kaspatest:pzg7r3p9wthvxxjtm74k7nlznrl9rjcfxjkx7txmslss2gyzw3xvj686vxecj", "P2SH address of the genesis gap")
    var rejected = j
    rejected["is_accepted"] = false
    r.check((try? KN.TxView.fromREST(rejected)) == .some(nil), "REST: a transaction not accepted is skipped")

    // indexer shapes
    let nameJSON = Data("""
    {"name":"Alice","key":"00","registered":true,"status":"active","owner":"kaspatest:x","ownerKey":"\(String(repeating: "ab", count: 32))",
     "price":"5000000000","expiresAt":1822000000000,"outpoint":{"txId":"\(String(repeating: "cd", count: 32))","index":2},"registeredAt":1790000000000}
    """.utf8)
    let n = try! JSONDecoder().decode(KN.IndexerAPI.NameJSON.self, from: nameJSON).info { _ in nil }
    r.eq(n?.name, "alice", "indexer name normalized")
    r.eq(n?.price, 5_000_000_000, "indexer price string")
    r.eq(n?.outpoint.index, 2, "indexer outpoint")
    r.eq(n?.key, KN.Codec.key("alice"), "indexer key recomputed from the name")
    r.eq(n?.periodStart, nil, "indexer without periodStart: unknown")
    let withPeriod = Data("""
    {"name":"alice","registered":true,"ownerKey":"\(String(repeating: "ab", count: 32))","price":"0","periodStart":1790000000000,
     "expiresAt":1822000000000,"outpoint":{"txId":"\(String(repeating: "cd", count: 32))","index":0}}
    """.utf8)
    let np = try! JSONDecoder().decode(KN.IndexerAPI.NameJSON.self, from: withPeriod).info { _ in nil }
    r.eq(np?.periodStart, 1_790_000_000_000, "indexer periodStart")
    r.eq(np?.fields?.periodStart, 1_790_000_000_000, "indexer record spendable with its periodStart")
    let free = Data("""
    {"name":"bob","key":"00","registered":false,"gap":{"lo":"\(String(repeating: "00", count: 32))","hi":"\(String(repeating: "ff", count: 32))","outpoint":{"txId":"\(String(repeating: "ee", count: 32))","index":0}}}
    """.utf8)
    let f = try! JSONDecoder().decode(KN.IndexerAPI.NameJSON.self, from: free)
    r.check(f.info { _ in nil } == nil, "indexer free name has no record")
    r.check(f.gap?.info?.contains(KN.Codec.key("bob")) == true, "indexer gap decoded")

    // registry v3: offers carry the seller; an indexer without it gives no offer
    let ab = String(repeating: "ab", count: 32), cd = String(repeating: "cd", count: 32)
    let keyOf: (String) -> Data? = { $0 == "kaspatest:buyer" ? try? KN.unhex32(ab) : $0 == "kaspatest:seller" ? try? KN.unhex32(cd) : nil }
    let offerJSON = Data("""
    {"outpoint":{"txId":"\(cd)","index":0},"buyer":"kaspatest:buyer","seller":"kaspatest:seller","amount":"500000000","refundAfter":7,"name":"alice"}
    """.utf8)
    let o = try! JSONDecoder().decode(KN.IndexerAPI.OfferJSON.self, from: offerJSON).info(name: nil, keyOf: keyOf)
    r.eq(o.map { KN.hex($0.seller) }, cd, "indexer offer seller")
    r.eq(o?.amount, 500_000_000, "indexer offer amount")
    let v2Offer = Data("""
    {"outpoint":{"txId":"\(cd)","index":0},"buyer":"kaspatest:buyer","amount":"500000000","refundAfter":7,"name":"alice"}
    """.utf8)
    r.check(try! JSONDecoder().decode(KN.IndexerAPI.OfferJSON.self, from: v2Offer).info(name: nil, keyOf: keyOf) == nil, "an offer without a seller is dropped")
}

/// Read-only walk of the live testnet-10 registry through the REST API.
func runLive(mainnet: Bool = false) async -> Bool {
    let base = mainnet ? "https://api.kaspa.org" : "https://api-tn10.kaspa.org"
    let hrp = mainnet ? "kaspa" : "kaspatest"
    let m: KN.Manifest
    do {
        m = try KN.Manifest.decode(Data(contentsOf: URL(fileURLWithPath: "KaChat/Resources/kachat-names-\(mainnet ? "mainnet" : "testnet-10").json")))
        try m.verify()
    } catch {
        // the bundled manifest stays an earlier registry's until the v3 genesis: nothing live to walk yet
        print("live: the bundled manifest does not verify: \(error)")
        return false
    }
    func get(_ path: String) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: base + path)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw KN.Failure("GET \(path): \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try JSONSerialization.jsonObject(with: data)
    }
    var state = KN.RegistryState.atGenesis(m)
    do {
        let report = try await state.walk(
            manifest: m,
            address: { KaspaAddress.address(fromScriptPublicKey: $0, hrp: hrp) },
            live: { addresses in
                var out = Set<String>()
                for a in addresses {
                    for u in try await get("/addresses/\(a)/utxos") as! [J] {
                        let op = u["outpoint"] as! J
                        out.insert("\(s(op["transactionId"])):\(u64(op["index"]))")
                    }
                }
                return out
            },
            transactions: { a, _ in
                try (try await get("/addresses/\(a)/full-transactions?limit=50&offset=0&resolve_previous_outpoints=no") as! [J]).compactMap { try KN.TxView.fromREST($0) }
            }
        )
        try state.checkInvariants()
        print("live \(mainnet ? "mainnet" : "TN10") registry \(KN.hex(m.registryCovenantId).prefix(16))...: \(report.rounds) round(s), \(report.applied.count) transaction(s) walked, \(state.gaps.count) gap(s), \(state.names.count) name(s), unresolved \(report.unresolved.count)")
        for g in state.gaps { print("  gap \(g.lo.prefix(8))..-\(g.hi.prefix(8)).. at \(g.txid.prefix(16)):\(g.index)") }
        for n in state.names { print("  name \(n.name).kachat owner \(n.owner.prefix(16)).. price \(n.price) expires \(n.expiresAt) at \(n.txid.prefix(16)):\(n.index)") }
        for e in state.events { print("  event \(e.op) \(e.name ?? "?") \(e.txId.prefix(16))") }
        return true
    } catch {
        print("live walk failed: \(error)")
        return false
    }
}

@main
struct KachatNamesRegistryTest {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)   // progress survives a trap
        let args = CommandLine.arguments
        let r = Report()
        // the vectors file: the v4 set by default, or another (KaChatTests/KachatNamesVectors-v5.json)
        let path = args.dropFirst().first { $0.hasSuffix(".json") } ?? "KaChatTests/KachatNamesVectors.json"
        let v = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! J
        lead = (v["steps"] as! [J]).prefix { s($0["op"]) == "import" }.count
        runRules(r)
        print("rules: \(r.pass) pass, \(r.fail) fail")
        runREST(r)
        print("+ REST and indexer shapes: \(r.pass) pass, \(r.fail) fail")
        runWalker(v, r)
        print("+ walker over the vectors: \(r.pass) pass, \(r.fail) fail")
        await runWalk(v, r)
        print("+ walk over a simulated chain: \(r.pass) pass, \(r.fail) fail")
        await runWalkOrders(v, r)
        print("+ walks in any order: \(r.pass) pass, \(r.fail) fail")
        for f in r.failures.prefix(40) { print("  FAIL " + f) }
        var ok = r.fail == 0
        if args.contains("--live") { ok = await runLive() && ok }
        if args.contains("--live-mainnet") { ok = await runLive(mainnet: true) && ok }
        if !ok { exit(1) }
        print("OK")
    }
}
