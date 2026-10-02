import Foundation

// The .kachat name core (KaChat/Services/KachatNames, pure part) against the kachat-domains test
// vectors (KaChatTests/KachatNamesVectors.json, written by `kachat-names-vectors` from the CLI's
// own builders) and the official BLAKE3 test vectors. Run from the repo root with:
//
// swiftc -O -parse-as-library KaChat/Utilities/Blake3.swift KaChat/Services/Blake2b.swift \
//   KaChat/Services/KachatNames/KachatNamesCodec.swift KaChat/Services/KachatNames/KachatNamesTransaction.swift \
//   KaChat/Services/KachatNames/KachatNamesManifest.swift KaChat/Services/KachatNames/KachatNamesBuilder.swift \
//   scripts/test_kachat_names_core.swift -o /tmp/kachat_names_core_test && /tmp/kachat_names_core_test
//
// `/tmp/kachat_names_core_test KaChatTests/KachatNamesVectors.json /tmp/fixed.json` also writes every
// transaction rebuilt with the app's fixed compute budgets, for `kachat-names-vectors check /tmp/fixed.json`
// in kachat-domains (the consensus validator signs the placeholders and validates them).

/// Official BLAKE3 test vectors (github.com/BLAKE3-team/BLAKE3 test_vectors.json): input byte i is
/// i % 251, key "whats the Elvish word for friend"; the first 32 bytes of each output.
let blake3Official: [(Int, String, String)] = [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213", "6d7878dfff2f485635d39013278ae14f1454b8c0a3a2d34bc1ab38228a80c95b"),
        (2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63", "5392ddae0e0a69d5f40160462cbd9bd889375082ff224ac9c758802b7a6fd20a"),
        (3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f", "39e67b76b5a007d4921969779fe666da67b5213b096084ab674742f0d5ec62b9"),
        (4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32", "7671dde590c95d5ac9616651ff5aa0a27bee5913a348e053b8aa9108917fe070"),
        (5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2", "73ac69eecf286894d8102018a6fc729f4b1f4247d3703f69bdc6a5fe3e0c8461"),
        (6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844", "82d3199d0013035682cc7f2a399d4c212544376a839aa863a0f4c91220ca7a6d"),
        (7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe", "af0a7ec382aedc0cfd626e49e7628bc7a353a4cb108855541a5651bf64fbb28a"),
        (8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb", "be2f5495c61cba1bb348a34948c004045e3bd4dae8f0fe82bf44d0da245a0600"),
        (63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b", "bb1eb5d4afa793c1ebdd9fb08def6c36d10096986ae0cfe148cd101170ce37ae"),
        (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98", "ba8ced36f327700d213f120b1a207a3b8c04330528586f414d09f2f7d9ccb7e6"),
        (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee", "c0a4edefa2d2accb9277c371ac12fcdbb52988a86edc54f0716e1591b4326e72"),
        (127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d", "c64200ae7dfaf35577ac5a9521c47863fb71514a3bcad18819218b818de85818"),
        (128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef", "b04fe15577457267ff3b6f3c947d93be581e7e3a4b018679125eaf86f6a628ec"),
        (129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12", "d4a64dae6cdccbac1e5287f54f17c5f985105457c1a2ec1878ebd4b57e20d38f"),
        (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11", "c951ecdf03288d0fcc96ee3413563d8a6d3589547f2c2fb36d9786470f1b9d6e"),
        (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7", "75c46f6f3d9eb4f55ecaaee480db732e6c2105546f1e675003687c31719c7ba4"),
        (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444", "357dc55de0c7e382c900fd6e320acc04146be01db6a8ce7210b7189bd664ea69"),
        (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a", "879cf1fa2ea0e79126cb1063617a05b6ad9d0b696d0d757cf053439f60a99dd1"),
        (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030", "9f29700902f7c86e514ddc4df1e3049f258b2472b6dd5267f61bf13983b78dd5"),
        (3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2", "044a0e7b172a312dc02a4c9a818c036ffa2776368d7f528268d2e6b5df191770"),
        (3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3", "68dede9bef00ba89e43f31a6825f4cf433389fedae75c04ee9f0cf16a427c95a"),
        (4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969", "befc660aea2f1718884cd8deb9902811d332f4fc4a38cf7c7300d597a081bfc0"),
        (4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995", "00df940cd36bb9fa7cbbc3556744e0dbc8191401afe70520ba292ee3ca80abbc"),
        (5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833", "2c493e48e9b9bf31e0553a22b23503c0a3388f035cece68eb438d22fa1943e20"),
        (5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff", "6ccf1c34753e7a044db80798ecd0782a8f76f33563accaddbfbb2e0ea4b2d024"),
        (6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205", "3d6b6d21281d0ade5b2b016ae4034c5dec10ca7e475f90f76eac7138e9bc8f1d"),
        (6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f", "9ac301e9e39e45e3250a7e3b3df701aa0fb6889fbd80eeecf28dbc6300fbc539"),
        (7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a", "b42835e40e9d4a7f42ad8cc04f85a963a76e18198377ed84adddeaecacc6f3fc"),
        (7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817", "ed9b1a922c046fdb3d423ae34e143b05ca1bf28b710432857bf738bcedbfa511"),
        (8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63", "dc9637c8845a770b4cbf76b8daec0eebf7dc2eac11498517f08d44c8fc00d58a"),
        (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b", "954a2a75420c8d6547e3ba5b98d963e6fa6491addc8c023189cc519821b4a1f5"),
        (16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4", "9e9fc4eb7cf081ea7c47d1807790ed211bfec56aa25bb7037784c13c4b707b0d"),
        (31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47", "efa53b389ab67c593dba624d898d0f7353ab99e4ac9d42302ee64cbf9939a419"),
        (102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085", "1c35d1a5811083fd7119f5d5d1ba027b4d01c0c6c49fb6ff2cf75393ea5db4a7")
]

func runBlake3Official(_ r: Report) {
    let key = [UInt8]("whats the Elvish word for friend".utf8)
    for (n, hash, keyed) in blake3Official {
        let input = (0..<n).map { UInt8($0 % 251) }
        r.eqHex(Blake3.hash(input), hash, "BLAKE3 official hash, len \(n)")
        r.eqHex(Blake3.keyedHash(key: key, Data(input)), keyed, "BLAKE3 official keyed hash, len \(n)")
        var inc = Blake3()
        var i = 0, step = 1
        while i < n { let e = min(n, i + step); inc.update(Array(input[i..<e])); i = e; step = step * 3 % 1031 + 1 }
        r.eqHex(inc.finalize(), hash, "BLAKE3 official hash, incremental, len \(n)")
    }
}

typealias KN = KachatNames
typealias J = [String: Any]

final class Report {
    var pass = 0
    var fail = 0
    var failures: [String] = []
    func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { pass += 1 } else { fail += 1; failures.append(what()) }
    }
    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        check(a == b, "\(what): got \(a) expected \(b)")
    }
    func eqHex(_ a: Data, _ b: String, _ what: String) {
        let h = KN.hex(a)
        check(h == b, "\(what): got \(h.prefix(160)) expected \(b.prefix(160))")
    }
}

func u64(_ v: Any?) -> UInt64 { (v as! NSNumber).uint64Value }
func i64(_ v: Any?) -> Int64 { (v as! NSNumber).int64Value }
func s(_ v: Any?) -> String { v as! String }
func hx(_ v: Any?) -> Data { try! KN.unhex(v as! String) }

func utxo(_ j: Any?) -> KN.Utxo {
    let u = j as! J
    let cov = u["covenantId"] as? String
    return KN.Utxo(
        outpoint: KN.Outpoint(txid: hx(u["txid"]), index: UInt32(u64(u["index"]))),
        entry: KN.UtxoEntry(
            amount: u64(u["amount"]), scriptVersion: UInt16(u64(u["scriptVersion"])), script: hx(u["script"]),
            blockDaaScore: u64(u["blockDaaScore"]), isCoinbase: u["isCoinbase"] as! Bool,
            covenantId: cov.map { try! KN.unhex($0) }
        )
    )
}

func gapRec(_ j: Any?) -> KN.GapRecord {
    let g = j as! J
    return KN.GapRecord(lo: hx(g["lo"]), hi: hx(g["hi"]), value: u64(g["value"]), utxo: utxo(g["utxo"]))
}

func nameRec(_ j: Any?) -> KN.NameRecord {
    let n = j as! J
    let name = s(n["name"])
    let f = KN.NameFields(key: hx(n["key"]), paddedName: KN.Codec.padded(name), owner: hx(n["owner"]), price: i64(n["price"]), expiresAt: i64(n["expiresAt"]))
    return KN.NameRecord(fields: f, value: u64(n["value"]), utxo: utxo(n["utxo"]))
}

func offerRec(_ j: Any?) -> KN.OfferRecord {
    let o = j as! J
    let f = KN.OfferFields(key: hx(o["key"]), buyer: hx(o["buyer"]), refundAfter: i64(o["refundAfter"]))
    return KN.OfferRecord(fields: f, value: u64(o["value"]), utxo: utxo(o["utxo"]), name: o["name"] as? String)
}

func commitRec(_ j: Any?) -> KN.CommitRecord {
    let c = j as! J
    return KN.CommitRecord(name: s(c["name"]), owner: hx(c["owner"]), salt: hx(c["salt"]), value: u64(c["value"]), utxo: utxo(c["utxo"]))
}

func runCodecs(_ v: J, _ r: Report) {
    let c = v["codecs"] as! J
    for k in c["nameKeys"] as! [J] {
        let name = s(k["name"])
        r.eqHex(KN.Codec.key(name), s(k["key"]), "key(\(name))")
        r.eqHex(KN.Codec.padded(name), s(k["padded"]), "padded(\(name))")
        r.check(KN.Codec.isValid(name), "valid \(name)")
    }
    for k in c["commitments"] as! [J] {
        let name = s(k["name"])
        let cm = KN.Codec.commitment(name: name, owner: hx(k["owner"]), salt: hx(k["salt"]))
        r.eqHex(cm, s(k["commitment"]), "commitment(\(name))")
        let redeem = KN.Codec.commitRedeem(commitment: cm, owner: hx(k["owner"]))
        r.eqHex(redeem, s(k["redeem"]), "commitRedeem(\(name))")
        r.eqHex(KN.Codec.p2shScript(redeem), s(k["spk"]), "commit spk(\(name))")
    }
    for b in c["blake3"] as! [J] {
        let n = Int(u64(b["len"]))
        let input = Data((0..<n).map { UInt8(($0 * 7) % 256) })
        r.eqHex(Blake3.hash(input), s(b["hash"]), "blake3 len \(n) vs Rust blake3::hash")
    }
    for x in c["num8"] as! [J] {
        let val = Int64(s(x["value"]))!
        r.eqHex(KN.Codec.num8(val), s(x["num8"]), "num8(\(val))")
        r.eq(try! KN.Codec.decodeNum8(KN.Codec.num8(val)), val, "decodeNum8(\(val))")
    }
    for x in c["scriptNumbers"] as! [J] {
        let val = Int64(s(x["value"]))!
        r.eqHex(KN.Codec.pushInt(val), s(x["push"]), "pushInt(\(val))")
    }
    for x in c["pushes"] as! [J] {
        r.eqHex(KN.Codec.pushData(hx(x["data"])), s(x["push"]), "pushData(len \(hx(x["data"]).count))")
        r.eq(try! KN.Codec.parsePushes(hx(x["push"])), [hx(x["data"]).count == 1 && hx(x["data"])[0] == 0x81 ? Data([0x81]) : hx(x["data"])], "parsePushes")
    }
    let st = c["states"] as! J
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let g = st["gap"] as! J
    let gs = KN.Codec.gapState(lo: hx(g["lo"]), hi: hx(g["hi"]))
    r.eqHex(gs, s(g["state"]), "gap state")
    r.eqHex(m.gap.script(gs), s(g["spk"]), "gap spk")
    let n = st["name"] as! J
    let nf = KN.NameFields(name: s(n["name"]), owner: hx(n["owner"]), price: i64(n["price"]), expiresAt: i64(n["expiresAt"]))
    r.eqHex(nf.encoded, s(n["state"]), "name state")
    r.eqHex(m.name.script(nf.encoded), s(n["spk"]), "name spk")
    r.eq(try! KN.Codec.decodeNameState(nf.encoded), nf, "decode name state")
    r.eq(nf.name, s(n["name"]), "unpadded name")
    let o = st["offer"] as! J
    let of = KN.OfferFields(key: hx(o["key"]), buyer: hx(o["buyer"]), refundAfter: i64(o["refundAfter"]))
    r.eqHex(of.encoded, s(o["state"]), "offer state")
    r.eqHex(m.offer.script(of.encoded), s(o["spk"]), "offer spk")
    r.eq(try! KN.Codec.decodeOfferState(of.encoded), of, "decode offer state")
    r.eq(KN.hex(try! KN.Codec.decodeGapState(gs).hi), s(g["hi"]), "decode gap state")
    for cv in c["covenantIds"] as! [J] {
        let op = cv["outpoint"] as! J
        let outpoint = KN.Outpoint(txid: hx(op["txid"]), index: UInt32(u64(op["index"])))
        let outs: [(index: UInt32, output: KN.TxOutput)] = (cv["outputs"] as! [J]).map {
            (UInt32(u64($0["index"])), KN.TxOutput(value: u64($0["value"]), scriptVersion: UInt16(u64($0["scriptVersion"])), script: hx($0["script"]), covenant: nil))
        }
        r.eqHex(KN.Codec.covenantId(outpoint: outpoint, authorized: outs), s(cv["covenantId"]), "covenant id (2 outputs)")
        r.eqHex(KN.Codec.covenantId(outpoint: outpoint, authorized: [outs[0]]), s(cv["covenantIdFirstOnly"]), "covenant id (1 output)")
    }
    let p = c["p2pk"] as! J
    r.eqHex(KN.Codec.p2pkScript(hx(p["xonly"])), s(p["spk"]), "p2pk spk")
    // silverscript template.rs golden values
    r.eqHex(KN.Codec.templateHash(prefix: Data(), suffix: Data()), "e572dff82304700b856a555ac3a4558d0df3646a3727816500270a93c66aac1e", "template hash golden (empty)")
    r.eqHex(KN.Codec.templateHash(prefix: Data([0x00, 0xff]), suffix: Data([0x10, 0x00, 0x80])), "6616a66757315de0221cb2acba729113cebde31f8d3ca7fa93878a0584b96905", "template hash golden (classic)")
    // name rules
    for bad in ["", "-a", "a-", "A", "a_b", "é", String(repeating: "a", count: 33), "a.b"] {
        r.check(!KN.Codec.isValid(bad), "invalid name accepted: \(bad)")
    }
    r.eq(KN.Codec.normalize("  Alice.KACHAT "), "alice", "normalize")
}

func runManifest(_ v: J, _ r: Report) -> KN.Manifest {
    let data = try! JSONSerialization.data(withJSONObject: v["manifest"]!)
    let m = try! KN.Manifest.decode(data)
    do { try m.verify(); r.pass += 1 } catch { r.check(false, "manifest verify: \(error)") }
    r.check(m.isDryRun, "the vectors' manifest is a dry run")
    // tampering is caught
    var j = v["manifest"] as! J
    j["registryCovenantId"] = String(repeating: "ab", count: 32)
    let bad = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: j))
    r.check((try? bad.verify()) == nil, "manifest with a wrong registry id verified")
    var j2 = v["manifest"] as! J
    var arts = j2["artifacts"] as! J
    var gapArt = arts["KachatGap"] as! J
    var suffix = s(gapArt["suffixHex"])
    suffix.removeLast(2); suffix += "00"
    gapArt["suffixHex"] = suffix
    arts["KachatGap"] = gapArt
    j2["artifacts"] = arts
    let bad2 = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: j2))
    r.check((try? bad2.verify()) == nil, "manifest with a tampered gap suffix verified")
    var j3 = v["manifest"] as! J
    j3["network"] = "mainnet"
    let bad3 = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: j3))
    r.check((try? bad3.verify()) == nil, "mainnet manifest verified")
    return m
}

struct StepResult { let label: String; let ok: Bool; let firstFailure: String? }

func runSteps(_ v: J, _ m: KN.Manifest, _ r: Report) -> [StepResult] {
    let b = try! KN.Builder(manifest: m)
    var results: [StepResult] = []
    let recommended = v["recommendedBudgets"] as! [String: Any]
    for st in v["steps"] as! [J] {
        let failBefore = r.fail
        let failuresBefore = r.failures.count
        let label = s(st["label"])
        let env0 = st["env"] as! J
        let exp = st["expected"] as! J
        let expInputs = exp["inputs"] as! [J]
        var budgets = KN.Budgets.recommended
        for i in expInputs {
            let role = KN.BudgetRole(rawValue: s(i["role"]))!
            let measured = UInt16(u64(i["computeBudget"]))
            r.check(measured <= KN.Budgets.recommended[role], "\(label): measured budget \(measured) > recommended for \(role)")
            r.eq(UInt64(KN.Budgets.recommended[role]), u64(recommended[role.rawValue]), "recommended table \(role.rawValue)")
            budgets[role] = measured
        }
        let env = KN.Env(me: hx(env0["me"]), blockDaa: u64(env0["blockDaa"]), blockTimeMs: u64(env0["blockTimeMs"]), wallMs: i64(env0["wallMs"]), feerate: (env0["feerate"] as! NSNumber).doubleValue, budgets: budgets)
        let wallet = (st["wallet"] as! [Any]).map(utxo)
        let args = st["args"] as! J
        let rec = st["records"] as! J
        let plan: KN.Plan
        do {
            switch s(st["op"]) {
            case "commit":
                plan = try b.commit(env: env, wallet: wallet, name: s(args["name"]), salt: hx(args["salt"]))
            case "register":
                plan = try b.register(env: env, wallet: wallet, gap: gapRec(rec["gap"]), commit: commitRec(rec["commit"]), years: i64(args["years"]), now: i64(args["now"]))
                r.eq(KN.Builder.registerNow(env: env), i64(args["now"]) + (label.contains("lapse") ? 376 * 86_400_000 : 0), "\(label): registerNow")
            case "renew":
                plan = try b.renew(env: env, wallet: wallet, name: nameRec(rec["name"]), years: i64(args["years"]))
            case "transfer":
                plan = try b.transfer(env: env, wallet: wallet, name: nameRec(rec["name"]), newOwner: hx(args["newOwner"]))
            case "list":
                plan = try b.list(env: env, wallet: wallet, name: nameRec(rec["name"]), price: u64(args["price"]))
            case "buy":
                plan = try b.buy(env: env, wallet: wallet, name: nameRec(rec["name"]))
            case "offer":
                plan = try b.offer(env: env, wallet: wallet, name: s(args["name"]), amount: u64(args["amount"]), refundAfter: u64(args["refundAfter"]), target: rec["target"].map(nameRec))
            case "acceptOffer":
                plan = try b.acceptOffer(env: env, name: nameRec(rec["name"]), offer: offerRec(rec["offer"]))
            case "withdrawOffer":
                plan = try b.withdrawOffer(env: env, offer: offerRec(rec["offer"]))
            case "refundOffer":
                plan = try b.refundOffer(env: env, offer: offerRec(rec["offer"]))
            case "release":
                plan = try b.release(env: env, parts: KN.ExitParts(below: gapRec(rec["below"]), name: nameRec(rec["name"]), above: gapRec(rec["above"])))
            case "reclaim":
                plan = try b.reclaim(env: env, parts: KN.ExitParts(below: gapRec(rec["below"]), name: nameRec(rec["name"]), above: gapRec(rec["above"])))
            default:
                r.check(false, "unknown op \(s(st["op"]))"); continue
            }
        } catch {
            r.check(false, "\(label): builder threw \(error)")
            results.append(StepResult(label: label, ok: false, firstFailure: "\(error)"))
            continue
        }
        let tx0 = plan.unsignedTx
        r.eq(plan.op, label, "\(label): op label")
        r.eq(tx0.inputs.count, expInputs.count, "\(label): input count")
        let expOutputs = exp["outputs"] as! [J]
        r.eq(tx0.outputs.count, expOutputs.count, "\(label): output count")
        r.eq(UInt64(tx0.version), u64(exp["version"]), "\(label): version")
        r.eq(tx0.lockTime, u64(exp["lockTime"]), "\(label): lock time")
        r.eqHex(tx0.payload, s(exp["payload"]), "\(label): payload")
        r.eqHex(tx0.subnetworkId, s(exp["subnetworkId"]), "\(label): subnetwork")
        r.eq(tx0.storageMass, u64(exp["storageMass"]), "\(label): storage mass")
        r.eq(plan.costs.size, u64(exp["size"]), "\(label): size")
        r.eq(plan.costs.computeMass, u64(exp["computeMass"]), "\(label): compute mass")
        r.eq(plan.costs.transientMass, u64(exp["transientMass"]), "\(label): transient mass")
        r.eq(plan.costs.normalizedTransient, u64(exp["normalizedTransient"]), "\(label): normalized transient")
        r.eq(plan.costs.minFee, u64(exp["minFee"]), "\(label): min fee")
        r.eq(plan.priceFee, u64(exp["priceFee"]), "\(label): price fee")
        r.eq(plan.networkFee, u64(exp["networkFee"]), "\(label): network fee")
        r.eq(plan.fee, u64(exp["fee"]), "\(label): fee")
        r.eqHex(tx0.restPreimage, s(exp["restPreimage"]), "\(label): rest preimage (unsigned)")
        r.eqHex(plan.txid, s(exp["txid"]), "\(label): txid (unsigned)")
        let sighashes = plan.sighashes
        var sigs: [Int: Data] = [:]
        for (i, ei) in expInputs.enumerated() where i < tx0.inputs.count {
            let ti = tx0.inputs[i]
            r.eqHex(ti.outpoint.txid, s(ei["txid"]), "\(label): input \(i) txid")
            r.eq(UInt64(ti.outpoint.index), u64(ei["index"]), "\(label): input \(i) index")
            r.eq(ti.sequence, u64(ei["sequence"]), "\(label): input \(i) sequence")
            r.eq(UInt64(ti.computeBudget), u64(ei["computeBudget"]), "\(label): input \(i) budget")
            r.eq(plan.inputs[i].role.rawValue, s(ei["role"]), "\(label): input \(i) role")
            r.eq(plan.entries[i], utxo(ei["entry"]).entry, "\(label): input \(i) entry")
            r.eqHex(sighashes[i], s(ei["sighash"]), "\(label): input \(i) sighash")
            let es = ei["signatures"] as! [String]
            r.eq(plan.inputs[i].unlock.needsSignature, !es.isEmpty, "\(label): input \(i) needs a signature")
            if let first = es.first { sigs[i] = hx(first) }
        }
        for (k, eo) in expOutputs.enumerated() where k < tx0.outputs.count {
            let o = tx0.outputs[k]
            r.eq(o.value, u64(eo["value"]), "\(label): output \(k) value")
            r.eqHex(o.script, s(eo["script"]), "\(label): output \(k) script")
            if let c = eo["covenant"] as? J {
                r.eq(o.covenant?.authorizingInput, UInt16(u64(c["authorizingInput"])), "\(label): output \(k) authorizing input")
                r.eq(o.covenant.map { KN.hex($0.covenantId) }, s(c["covenantId"]), "\(label): output \(k) covenant id")
            } else {
                r.check(o.covenant == nil, "\(label): output \(k) has a covenant binding")
            }
        }
        do {
            let signed = try plan.signed(signatures: sigs)
            for (i, ei) in expInputs.enumerated() where i < signed.inputs.count {
                r.eqHex(signed.inputs[i].signatureScript, s(ei["signatureScript"]), "\(label): input \(i) signature script")
            }
            r.eqHex(signed.fullPreimage, s(exp["fullPreimage"]), "\(label): full preimage (signed)")
            r.eqHex(signed.hash, s(exp["txHash"]), "\(label): tx hash (signed)")
            r.eqHex(signed.id, s(exp["txid"]), "\(label): txid (signed)")
            r.eqHex(signed.restPreimage, s(exp["restPreimage"]), "\(label): rest preimage (signed)")
            // the signer path calls back once per signing input with that input's sighash
            var seen: [Data] = []
            let viaSigner = try plan.signed { h in seen.append(h); return Data(repeating: 0x11, count: 64) }
            r.eq(seen, sighashes.enumerated().filter { plan.inputs[$0.offset].unlock.needsSignature }.map { $0.element }, "\(label): signer sees the sighashes")
            r.eq(viaSigner.inputs.map { $0.signatureScript.count }, signed.inputs.map { $0.signatureScript.count }, "\(label): signature script lengths")
        } catch {
            r.check(false, "\(label): signing threw \(error)")
        }
        if let nc = plan.newCommit {
            r.eq(nc.name, s(args["name"]), "\(label): new commit name")
        }
        let ok = r.fail == failBefore
        results.append(StepResult(label: label, ok: ok, firstFailure: ok ? nil : r.failures[failuresBefore]))
    }
    return results
}

func runVectors(_ path: String) -> Bool {
    let v = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! J
    let r = Report()
    runBlake3Official(r)
    print("blake3 official vectors: \(r.pass) checks pass, \(r.fail) fail")
    runCodecs(v, r)
    print("blake3 + codecs: \(r.pass) checks pass, \(r.fail) fail")
    let m = runManifest(v, r)
    let results = runSteps(v, m, r)
    for res in results {
        print((res.ok ? "MATCH  " : "DIFFER ") + res.label + (res.firstFailure.map { "   <- " + $0 } ?? ""))
    }
    print("vectors: \(r.pass) checks pass, \(r.fail) fail; \(results.filter { $0.ok }.count)/\(results.count) transactions byte-identical")
    for f in r.failures.prefix(40) { print("  FAIL " + f) }
    return r.fail == 0
}

/// Builds every vector step again with the app's fixed (recommended) budgets and writes the
/// transactions, with placeholder signatures, for `kachat-names-vectors check`.
func writeFixedBudget(_ path: String, _ out: String) {
    let v = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! J
    let m = try! KN.Manifest.decode(JSONSerialization.data(withJSONObject: v["manifest"]!))
    let b = try! KN.Builder(manifest: m)
    var txs: [J] = []
    func entryJSON(_ e: KN.UtxoEntry) -> J {
        ["amount": e.amount, "scriptVersion": e.scriptVersion, "script": KN.hex(e.script), "blockDaaScore": e.blockDaaScore,
         "isCoinbase": e.isCoinbase, "covenantId": e.covenantId.map { KN.hex($0) } ?? NSNull()]
    }
    for st in v["steps"] as! [J] {
        let env0 = st["env"] as! J
        let env = KN.Env(me: hx(env0["me"]), blockDaa: u64(env0["blockDaa"]), blockTimeMs: u64(env0["blockTimeMs"]), wallMs: i64(env0["wallMs"]))
        let wallet = (st["wallet"] as! [Any]).map(utxo)
        let args = st["args"] as! J
        let rec = st["records"] as! J
        let plan: KN.Plan
        switch s(st["op"]) {
        case "commit": plan = try! b.commit(env: env, wallet: wallet, name: s(args["name"]), salt: hx(args["salt"]))
        case "register": plan = try! b.register(env: env, wallet: wallet, gap: gapRec(rec["gap"]), commit: commitRec(rec["commit"]), years: i64(args["years"]), now: i64(args["now"]))
        case "renew": plan = try! b.renew(env: env, wallet: wallet, name: nameRec(rec["name"]), years: i64(args["years"]))
        case "transfer": plan = try! b.transfer(env: env, wallet: wallet, name: nameRec(rec["name"]), newOwner: hx(args["newOwner"]))
        case "list": plan = try! b.list(env: env, wallet: wallet, name: nameRec(rec["name"]), price: u64(args["price"]))
        case "buy": plan = try! b.buy(env: env, wallet: wallet, name: nameRec(rec["name"]))
        case "offer": plan = try! b.offer(env: env, wallet: wallet, name: s(args["name"]), amount: u64(args["amount"]), refundAfter: u64(args["refundAfter"]))
        case "acceptOffer": plan = try! b.acceptOffer(env: env, name: nameRec(rec["name"]), offer: offerRec(rec["offer"]))
        case "withdrawOffer": plan = try! b.withdrawOffer(env: env, offer: offerRec(rec["offer"]))
        case "refundOffer": plan = try! b.refundOffer(env: env, offer: offerRec(rec["offer"]))
        case "release": plan = try! b.release(env: env, parts: KN.ExitParts(below: gapRec(rec["below"]), name: nameRec(rec["name"]), above: gapRec(rec["above"])))
        case "reclaim": plan = try! b.reclaim(env: env, parts: KN.ExitParts(below: gapRec(rec["below"]), name: nameRec(rec["name"]), above: gapRec(rec["above"])))
        default: fatalError()
        }
        let tx = plan.unsignedTx
        // the refund and reclaim vectors run at the block their lock time needs (the CLI's notes say so)
        txs.append([
            "label": plan.op, "blockDaa": env.blockDaa, "blockTimeMs": env.blockTimeMs,
            "version": tx.version, "lockTime": tx.lockTime, "payload": KN.hex(tx.payload), "storageMass": tx.storageMass,
            "networkFee": plan.networkFee, "priceFee": plan.priceFee, "computeMass": plan.costs.computeMass, "txid": KN.hex(tx.id),
            "inputs": zip(tx.inputs, plan.entries).map { i, e in
                ["txid": KN.hex(i.outpoint.txid), "index": i.outpoint.index, "sequence": i.sequence, "computeBudget": i.computeBudget,
                 "signatureScript": KN.hex(i.signatureScript), "entry": entryJSON(e)] as J
            },
            "outputs": tx.outputs.map { o in
                ["value": o.value, "scriptVersion": o.scriptVersion, "script": KN.hex(o.script),
                 "covenant": o.covenant.map { ["authorizingInput": $0.authorizingInput, "covenantId": KN.hex($0.covenantId)] as J } ?? NSNull()] as J
            }
        ])
    }
    let doc: J = ["registryCovenantId": (v["manifest"] as! J)["registryCovenantId"]!, "signer": (v["deployer"] as! J)["xonly"]!, "transactions": txs]
    try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    print("wrote \(txs.count) fixed-budget transactions to \(out)")
}

@main
struct KachatNamesCoreTest {
    static func main() {
        let args = CommandLine.arguments
        let vectors = args.count > 1 ? args[1] : "KaChatTests/KachatNamesVectors.json"
        let ok = runVectors(vectors)
        if args.count > 2 { writeFixedBudget(vectors, args[2]) }
        if !ok { exit(1) }
        print("OK")
    }
}
