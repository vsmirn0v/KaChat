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
                                 price: i64(n["price"]), expiresAt: i64(n["expiresAt"]), value: u64(n["value"])))
    }
    if let o = rec["offer"] as? J {
        let u = o["utxo"] as! J
        state.offers.append(.init(txid: s(u["txid"]), index: UInt32(u64(u["index"])), key: s(o["key"]), buyer: s(o["buyer"]),
                                  refundAfter: i64(o["refundAfter"]), value: u64(o["value"]), name: o["name"] as? String))
    }
    return state
}

func runWalker(_ v: J, _ r: Report) {
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let steps = v["steps"] as! [J]
    let e2e = Array(steps.prefix(18))
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
    r.eq(ops, [
        "register alpha-tn", "register bravo-tn", "register lapse-tn", "renew alpha-tn", "transfer alpha-tn", "list alpha-tn",
        "sale alpha-tn", "offer bravo-tn", "offer_accepted bravo-tn", "offer_accept bravo-tn", "offer alpha-tn", "offer_refund alpha-tn",
        "offer alpha-tn", "offer_withdraw alpha-tn", "release bravo-tn", "reclaim lapse-tn"
    ], "e2e events")
    r.eq(state.names.map(\.name), ["alpha-tn"], "names left after the e2e plan")
    r.eq(state.gaps.count, 2, "gaps left after the e2e plan")
    r.eq(state.offers.count, 0, "offers left after the e2e plan")
    let accepted = state.events.first { $0.op == "offer_accepted" }
    r.check((accepted?.price ?? 0) > 9 * 100_000_000 && (accepted?.price ?? 0) < 10 * 100_000_000, "accepted offer payout is the offer less the fee")
    let alpha = state.name("alpha-tn")
    r.check(alpha?.registeredTxId == KN.hex(hx((e2e[3]["expected"] as! J)["txid"])), "registration tx carried through every transition")
    r.eq(alpha?.registeredAt, 1_003, "registration time carried through every transition")
    // applying again changes nothing
    let snapshot = state
    for (i, st) in e2e.enumerated() { _ = try? state.apply(view(st, at: Int64(1_000 + i)), manifest: m) }
    r.eq(state, snapshot, "re-applying is a no-op")

    // the edge cases, each on a state seeded with its own records
    for st in steps.dropFirst(18) {
        var seededState = seeded(st, m)
        let label = s(st["label"])
        do {
            let events = try seededState.apply(view(st, at: 5), manifest: m)
            let op = s(st["op"])
            if op == "commit" || op == "cancelCommit" { r.check(events.isEmpty, "\(label): not a registry transaction") } else { r.check(!events.isEmpty, "\(label): no events") }
            switch op {
            case "register": r.eq(seededState.names.count, 1, "\(label): name created"); r.eq(seededState.gaps.count, 2, "\(label): gaps split")
            case "reclaim": r.eq(seededState.names.count, 0, "\(label): name gone"); r.eq(seededState.gaps.count, 1, "\(label): gaps merged")
            case "acceptOffer": r.eq(seededState.offers.count, 0, "\(label): offer gone")
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

    // refusals leave the state alone
    let reg = steps[3]
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
    r.eq((try? st0.apply(view(steps[0], at: 1), manifest: m))?.count, 0, "a commit is not a registry transaction")
}

/// The walk loop over a simulated chain holding every e2e transaction: liveness from the
/// simulated UTXO set, spends found through addresses, transactions handed back newest first.
func runWalk(_ v: J, _ r: Report) async {
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let steps = Array((v["steps"] as! [J]).prefix(18))
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

    for upTo in [3, 6, 10, 18] {
        let visible = Array(txs.prefix(upTo))
        let visibleIds = Set(visible.map(\.idHex))
        var walked = KN.RegistryState.atGenesis(m)
        do {
            let report = try await walked.walk(
                manifest: m,
                address: addr,
                live: { addresses in
                    Set(created.filter { op, script in
                        addresses.contains(addr(script) ?? "") && (op.hasPrefix(KN.hex(m.genesisTxid)) || visibleIds.contains(String(op.prefix(64))))
                            && !(spentBy[op].map { visibleIds.contains($0) } ?? false)
                    }.keys)
                },
                transactions: { a in
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
            r.check(report.unresolved.isEmpty, "walk to \(upTo): unresolved \(report.unresolved)")
            do { try walked.checkInvariants() } catch { r.check(false, "walk to \(upTo): invariants \(error)") }
        } catch {
            r.check(false, "walk to \(upTo) threw \(error)")
        }
    }
    _ = expected
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
    let owned = [info("zeta", exp: now + 5, reg: 10), info("alpha", exp: now + 5, reg: 20), info("old", exp: now - 5, reg: 1)]
    r.eq(KN.label(owned: owned, primaryName: nil, graceMs: g, nowMs: now), "zeta", "label: the oldest active name")
    r.eq(KN.label(owned: owned, primaryName: "Alpha.kachat", graceMs: g, nowMs: now), "alpha", "label: the primary name")
    r.eq(KN.label(owned: owned, primaryName: "old", graceMs: g, nowMs: now), "zeta", "label: a primary name in grace is skipped")
    r.eq(KN.label(owned: owned, primaryName: "notmine", graceMs: g, nowMs: now), "zeta", "label: a primary name not owned is skipped")
    r.eq(KN.label(owned: [owned[2]], primaryName: nil, graceMs: g, nowMs: now), nil, "label: no active name")

    var p = KN.Profile()
    p.social = " x.com/KaspaCurrency/ "
    p.linktree = "https://www.linktr.ee/kaspa?utm=1"
    p.primaryName = "Alice.kachat"
    let clean = p.sanitized()
    r.eq(clean.social, "https://x.com/KaspaCurrency", "profile: social link normalized")
    r.eq(clean.linktree, "https://linktr.ee/kaspa", "profile: Linktree link normalized")
    r.eq(clean.primaryName, "alice", "profile: primary name normalized")
    var other = KN.Profile()
    other.social = "https://example.com/me"
    other.linktree = "https://example.com/links"
    r.eq(other.sanitized(), KN.Profile(), "profile: unsupported social site and non-Linktree link dropped")
    let json = try! p.recordJSON()
    r.check(json.count <= 2048, "profile JSON within 2 KB")
    r.eq(String(data: json, encoding: .utf8)!, "{\"linktree\":\"https://linktr.ee/kaspa\",\"primaryName\":\"alice\",\"social\":\"https://x.com/KaspaCurrency\",\"v\":1}", "profile JSON compact with sorted keys")
    r.eq(KN.Profile.parse(json), clean, "profile JSON round trip")
    r.eq(KN.Profile.parse(Data("{\"v\":1,\"displayName\":\"x\",\"bio\":\"free text\",\"social\":\"ftp://a\"}".utf8)), KN.Profile(), "profile: unknown fields (bio, display name) and bad links dropped")
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
    r.eq(SS.discordDescription(fromInviteJSON: Data("{\"guild\":{\"id\":\"1\",\"description\":\"Devs\"}}".utf8)), "Devs", "Discord server description")

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
    let free = Data("""
    {"name":"bob","key":"00","registered":false,"gap":{"lo":"\(String(repeating: "00", count: 32))","hi":"\(String(repeating: "ff", count: 32))","outpoint":{"txId":"\(String(repeating: "ee", count: 32))","index":0}}}
    """.utf8)
    let f = try! JSONDecoder().decode(KN.IndexerAPI.NameJSON.self, from: free)
    r.check(f.info { _ in nil } == nil, "indexer free name has no record")
    r.check(f.gap?.info?.contains(KN.Codec.key("bob")) == true, "indexer gap decoded")
}

/// Read-only walk of the live testnet-10 registry through the REST API.
func runLive() async -> Bool {
    let base = "https://api-tn10.kaspa.org"
    let m = try! KN.Manifest.decode(Data(contentsOf: URL(fileURLWithPath: "KaChat/Resources/kachat-names-testnet-10.json")))
    do { try m.verify() } catch { print("live: manifest does not verify: \(error)"); return false }
    func get(_ path: String) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: base + path)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw KN.Failure("GET \(path): \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try JSONSerialization.jsonObject(with: data)
    }
    var state = KN.RegistryState.atGenesis(m)
    do {
        let report = try await state.walk(
            manifest: m,
            address: { KaspaAddress.address(fromScriptPublicKey: $0, hrp: "kaspatest") },
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
            transactions: { a in
                try (try await get("/addresses/\(a)/full-transactions?limit=50&offset=0&resolve_previous_outpoints=no") as! [J]).compactMap { try KN.TxView.fromREST($0) }
            }
        )
        try state.checkInvariants()
        print("live TN10 registry \(KN.hex(m.registryCovenantId).prefix(16))...: \(report.rounds) round(s), \(report.applied.count) transaction(s) walked, \(state.gaps.count) gap(s), \(state.names.count) name(s), unresolved \(report.unresolved.count)")
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
        let args = CommandLine.arguments
        let r = Report()
        let v = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "KaChatTests/KachatNamesVectors.json"))) as! J
        runRules(r)
        print("rules: \(r.pass) pass, \(r.fail) fail")
        runREST(r)
        print("+ REST and indexer shapes: \(r.pass) pass, \(r.fail) fail")
        runWalker(v, r)
        print("+ walker over the vectors: \(r.pass) pass, \(r.fail) fail")
        await runWalk(v, r)
        print("+ walk over a simulated chain: \(r.pass) pass, \(r.fail) fail")
        for f in r.failures.prefix(40) { print("  FAIL " + f) }
        var ok = r.fail == 0
        if args.contains("--live") { ok = await runLive() && ok }
        if !ok { exit(1) }
        print("OK")
    }
}
