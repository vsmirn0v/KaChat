import Foundation

extension KachatNames {

    /// A compiled contract: `redeem = prefix || state || suffix`.
    struct Template: Equatable {
        let contract: String
        let prefix: Data
        let suffix: Data
        let stateLength: Int
        let templateHash: Data
        /// entry name -> 4-byte dispatch tag
        let dispatchTags: [String: Data]

        func redeem(_ state: Data) -> Data {
            var d = prefix
            d.append(state)
            d.append(suffix)
            return d
        }

        /// The P2SH script of `prefix || state || suffix`.
        func script(_ state: Data) -> Data { Codec.p2shScript(redeem(state)) }

        func tag(_ entry: String) throws -> Data {
            guard let t = dispatchTags[entry] else { throw Failure("\(contract) has no entry \(entry)") }
            return t
        }

        /// The state of a redeem script of this template (what a spend reveals).
        func state(ofRedeem redeem: Data) throws -> Data {
            guard redeem.count == prefix.count + stateLength + suffix.count,
                  redeem.prefix(prefix.count) == prefix,
                  redeem.suffix(suffix.count) == suffix else {
                throw Failure("not a \(contract) redeem script")
            }
            let start = redeem.startIndex + prefix.count
            return Data(redeem[start..<(start + stateLength)])
        }
    }

    /// The registry parameters (kachat-domains params/<network>.json, registry v4). The prices are
    /// fixed: baked into the gap and name templates (whose hashes are pinned), so these tables are
    /// what the contracts charge.
    struct Params: Equatable {
        let bond: UInt64
        let gapValue: UInt64
        let tCommit: UInt64
        /// most periods a name may be paid ahead
        let maxYears: Int64
        /// one paid period, ms: a year on mainnet, 10 minutes on the testnet-10 clock
        let periodMs: Int64
        let graceMs: Int64
        /// `renew` is valid from `expiresAt - renewWindowMs` on
        let renewWindowMs: Int64
        /// sompi for a name's first period, by length 1, 2, 3, 4, 5+ bytes
        let registerPrices: [UInt64]
        /// sompi for every further period (extend, renew, registering past one period)
        let renewPrices: [UInt64]
        let offerMaxFee: UInt64

        // MARK: Prices (registry v4: KachatGap.priceFor, KachatName.renewPrice)

        func registerPrice(forLength n: Int) -> UInt64 { registerPrices[Codec.tier(n)] }
        func renewPrice(forLength n: Int) -> UInt64 { renewPrices[Codec.tier(n)] }

        /// What `register` charges for `years` periods: the first at the registration price,
        /// every further one at the renewal price.
        func registerCost(forLength n: Int, years: Int64) -> UInt64 {
            registerPrice(forLength: n) + renewPrice(forLength: n) * UInt64(max(years - 1, 0))
        }

        // MARK: The paid period (KACHAT_NAMES.md 4.1; ops.rs)

        /// The most periods `extend` can add now: a name (from `periodStart`) holds at most
        /// `maxYears` periods (ops.rs `extendable_years`).
        func extendableYears(periodStart: Int64, expiresAt: Int64) -> Int64 {
            let room = periodStart + maxYears * periodMs - expiresAt
            return room < 0 ? 0 : min(room / periodMs, maxYears)
        }

        func extendableYears(_ f: NameFields) -> Int64 { extendableYears(periodStart: f.periodStart, expiresAt: f.expiresAt) }

        /// When `renew` becomes valid: `expiresAt - renewWindowMs` (unix ms). The transaction is
        /// final once the network's past median time passes its lock time, which is at least this.
        func renewOpens(expiresAt: Int64) -> Int64 { expiresAt - renewWindowMs }

        /// How close to expiry a name counts as "expires soon" (a buyer would have to renew it):
        /// 30 days on a yearly clock, the renewal window on a short one (testnet's 10 minutes),
        /// where 30 days would cover every name.
        var expiresSoonMs: Int64 { max(renewWindowMs, min(30 * 86_400_000, periodMs / 12)) }
    }

    /// The deployment manifest `kachat-names-<network>.json` (written by the kachat-domains CLI's
    /// `genesis`, served by the indexer at `GET /names/manifest`): params, every contract's prefix,
    /// suffix, template hash and dispatch tags, the registry covenant id and the genesis binding
    /// (registry v4: no price covenant). `verify()` must pass before anything
    /// trusts it.
    struct Manifest {
        static let supportedNetwork = "testnet-10"
        static let bundleResource = "kachat-names-testnet-10"

        /// Template hashes of the pinned build - registry v4 (silverc v1.0.0 @ 3ed9733), testnet-10
        /// params (kachat-domains artifacts/testnet10/build-info.json). The gap and the name bake
        /// only the params - their fixed prices included - so they are pinned before any genesis.
        /// The offer bakes the registry id, so its hash exists once the registry genesis does: the
        /// deployment adds it in `deployedTemplateHashes`. Until every template is pinned only a
        /// bundled manifest is trusted (`verify(source:)`), never one an indexer serves - an
        /// unpinned offer template could hold buyers' funds in a script the indexer controls
        /// (IOS-059).
        static let pinnedTemplateHashes: [String: String] = [
            "KachatGap": "85cf57f8d300331c2acc5191794065d60fafdd29cac90e3b82e3e1ba1c3876f0",
            "KachatName": "394204b612f345787412156521c0aabbd36bba30311f008302964d4c4ece685a"
        ]

        /// The price tables the pinned gap and name bake (kachat-domains params/testnet10.json): a
        /// manifest whose params say otherwise would show and charge prices the contracts don't.
        static let pinnedRegisterPrices: [UInt64] = [4_000_000_000, 2_000_000_000, 1_000_000_000, 250_000_000, 35_000_000]
        static let pinnedRenewPrices: [UInt64] = [1_000_000_000, 500_000_000, 250_000_000, 62_500_000, 8_750_000]

        /// The offer build each deployed registry was launched with, by registry covenant id. A
        /// manifest for one of these registries must carry exactly this; any other registry (a dry
        /// run, the test vectors) has no offer pin, so only a bundled manifest of it is trusted.
        static let deployedTemplateHashes: [String: [String: String]] = [
            // testnet-10 registry v4, 2026-10-07: genesis b1f28a5f..85a1
            "bff185546af1940ec70d74143e23b5f018fdb864bd02e15ca9b4c8d8ede40e2f": [
                "KachatOffer": "226def4b7fea21b21957c55fd47331b1d2f510fa2a63f8e7543bafaed4898e7d"
            ]
        ]
        static let stateLengths: [String: Int] = ["KachatGap": 66, "KachatName": 126, "KachatOffer": 108]
        static let entries: [String: [String]] = [
            "KachatGap": ["register", "merge", "absorbed"],
            "KachatName": ["transfer", "list", "buy", "extend", "renew", "release", "reclaim"],
            "KachatOffer": ["accept", "decline", "withdraw", "refund"]
        ]

        /// Where a manifest came from: the app bundle (shipped with the build) or an indexer.
        enum Source { case bundle, indexer }

        let network: String
        let status: String
        let params: Params
        let gap: Template
        let name: Template
        let offer: Template
        let registryCovenantId: Data
        let genesisTxid: Data
        let genesisOutpoint: Outpoint
        let genesisOutput: TxOutput
        let genesisState: (lo: Data, hi: Data)

        /// A manifest from a dry run describes a registry that does not exist.
        var isDryRun: Bool { status.hasPrefix("dry run") }

        // MARK: Decoding

        static func decode(_ data: Data) throws -> Manifest {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure("manifest: not a JSON object")
            }
            return try Manifest(json: root)
        }

        private static func str(_ v: Any?, _ what: String) throws -> String {
            guard let s = v as? String else { throw Failure("manifest: \(what) missing") }
            return s
        }

        private static func u64(_ v: Any?, _ what: String) throws -> UInt64 {
            guard let n = v as? NSNumber, n.int64Value >= 0 else { throw Failure("manifest: \(what) missing") }
            return n.uint64Value
        }

        private static func tiers(_ v: Any?, _ what: String) throws -> [UInt64] {
            guard let o = v as? [String: Any] else { throw Failure("manifest: \(what) missing") }
            return try ["len1", "len2", "len3", "len4", "len5plus"].map { try u64(o[$0], "\(what).\($0)") }
        }

        private static func template(_ artifacts: [String: Any], _ contract: String) throws -> Template {
            guard let a = artifacts[contract] as? [String: Any] else { throw Failure("manifest: \(contract) missing") }
            let prefix = try unhex(try str(a["prefixHex"], "\(contract).prefixHex"))
            let suffix = try unhex(try str(a["suffixHex"], "\(contract).suffixHex"))
            let hash = try unhex32(try str(a["templateHash"], "\(contract).templateHash"))
            guard let tagsJSON = a["dispatchTags"] as? [String: Any] else { throw Failure("manifest: \(contract).dispatchTags missing") }
            var tags: [String: Data] = [:]
            for (k, v) in tagsJSON {
                let t = try unhex(try str(v, "\(contract).dispatchTags.\(k)"))
                guard t.count == 4 else { throw Failure("manifest: \(contract) dispatch tag \(k) is not 4 bytes") }
                tags[k] = t
            }
            let stateLength = stateLengths[contract] ?? 0
            // the declared lengths and state span must agree with the bytes
            if let pl = a["prefixLen"] as? NSNumber, pl.intValue != prefix.count { throw Failure("manifest: \(contract).prefixLen") }
            if let sl = a["suffixLen"] as? NSNumber, sl.intValue != suffix.count { throw Failure("manifest: \(contract).suffixLen") }
            if let span = a["stateSpan"] as? [String: Any] {
                guard (span["offset"] as? NSNumber)?.intValue == prefix.count,
                      (span["len"] as? NSNumber)?.intValue == stateLength else {
                    throw Failure("manifest: \(contract).stateSpan")
                }
            }
            if let bl = a["bytecodeLen"] as? NSNumber, bl.intValue != prefix.count + stateLength + suffix.count {
                throw Failure("manifest: \(contract).bytecodeLen")
            }
            return Template(contract: contract, prefix: prefix, suffix: suffix, stateLength: stateLength, templateHash: hash, dispatchTags: tags)
        }

        private static func outpoint(_ v: Any?, _ what: String) throws -> Outpoint {
            let op = try str(v, what).split(separator: ":")
            guard op.count == 2, let idx = UInt32(op[1]) else { throw Failure("manifest: \(what)") }
            return Outpoint(txid: try unhex32(String(op[0])), index: idx)
        }

        init(json root: [String: Any]) throws {
            network = try Self.str(root["network"], "network")
            status = (root["status"] as? String) ?? ""
            // registry v1 - v3 manifests describe contracts this app no longer builds for: it waits
            // for the v4 genesis
            guard (root["registryVersion"] as? NSNumber)?.intValue == 4 else { throw Failure.outdatedRegistry }
            guard let p = root["params"] as? [String: Any] else { throw Failure("manifest: params missing") }
            params = Params(
                bond: try Self.u64(p["bond"], "bond"),
                gapValue: try Self.u64(p["gapValue"], "gapValue"),
                tCommit: try Self.u64(p["tCommit"], "tCommit"),
                maxYears: Int64(try Self.u64(p["maxYears"], "maxYears")),
                periodMs: Int64(try Self.u64(p["periodMs"], "periodMs")),
                graceMs: Int64(try Self.u64(p["graceMs"], "graceMs")),
                renewWindowMs: Int64(try Self.u64(p["renewWindowMs"], "renewWindowMs")),
                registerPrices: try Self.tiers((p["prices"] as? [String: Any])?["register"], "prices.register"),
                renewPrices: try Self.tiers((p["prices"] as? [String: Any])?["renew"], "prices.renew"),
                offerMaxFee: try Self.u64(p["offerMaxFee"], "offerMaxFee")
            )
            guard let artifacts = root["artifacts"] as? [String: Any] else { throw Failure("manifest: artifacts missing") }
            gap = try Self.template(artifacts, "KachatGap")
            name = try Self.template(artifacts, "KachatName")
            offer = try Self.template(artifacts, "KachatOffer")
            registryCovenantId = try unhex32(try Self.str(root["registryCovenantId"], "registryCovenantId"))
            guard let g = root["genesis"] as? [String: Any] else { throw Failure("manifest: genesis missing") }
            genesisTxid = try unhex32(try Self.str(g["txid"], "genesis.txid"))
            genesisOutpoint = try Self.outpoint(g["outpoint"], "genesis.outpoint")
            guard let outs = g["authorizedOutputs"] as? [[String: Any]], outs.count == 1 else {
                throw Failure("manifest: the genesis must authorize exactly one output")
            }
            let o = outs[0]
            guard (o["index"] as? NSNumber)?.intValue == 0 else { throw Failure("manifest: the genesis gap is not output 0") }
            genesisOutput = TxOutput(
                value: try Self.u64(o["value"], "genesis value"),
                scriptVersion: UInt16(try Self.u64(o["scriptPublicKeyVersion"], "genesis spk version")),
                script: try unhex(try Self.str(o["scriptPublicKey"], "genesis spk")),
                covenant: nil
            )
            guard let st = o["state"] as? [String: Any] else { throw Failure("manifest: genesis state missing") }
            genesisState = (try unhex32(try Self.str(st["lo"], "genesis lo")), try unhex32(try Self.str(st["hi"], "genesis hi")))
        }

        // MARK: Verification

        /// Checks everything the app relies on (KACHAT_NAMES_INDEXER.md B2, kachat-domains
        /// `manifest::load`): testnet-10 only; every template's hash recomputed from its prefix and
        /// suffix and equal to the pinned build where pinned (an indexer-served manifest needs every
        /// hash pinned); every dispatch tag present; the gap baked for this name template, the
        /// offer for this registry id and name template; both price tables complete and in range;
        /// the genesis output is the genesis gap `(00..00, ff..ff)` worth `gapValue`; and
        /// `registryCovenantId == covenant_id(genesis outpoint, [(0, genesis gap)])`.
        func verify(source: Source = .bundle) throws {
            guard network == Self.supportedNetwork else {
                throw Failure("manifest is for \(network); only \(Self.supportedNetwork) is enabled (mainnet waits for an audit)")
            }
            let pins = Self.pinnedTemplateHashes.merging(Self.deployedTemplateHashes[hex(registryCovenantId)] ?? [:]) { pinned, _ in pinned }
            for t in [gap, name, offer] {
                guard Codec.templateHash(prefix: t.prefix, suffix: t.suffix) == t.templateHash else {
                    throw Failure("manifest: \(t.contract) template hash does not match its prefix and suffix")
                }
                if let pinned = pins[t.contract] {
                    guard hex(t.templateHash) == pinned else { throw Failure("manifest: \(t.contract) is not the pinned build") }
                } else if source == .indexer {
                    throw Failure("manifest: \(t.contract) is not pinned in this app; only a bundled manifest is trusted")
                }
                for e in Self.entries[t.contract] ?? [] where t.dispatchTags[e] == nil {
                    throw Failure("manifest: \(t.contract) dispatch tag for \(e) missing")
                }
            }
            guard gap.suffix.range(of: name.templateHash) != nil else { throw Failure("manifest: the gap is not built for this name template") }
            guard offer.suffix.range(of: registryCovenantId) != nil, offer.suffix.range(of: name.templateHash) != nil else {
                throw Failure("manifest: the offer is not built for this registry id and name template")
            }
            let priceCap: UInt64 = 100_000_000_000_000_000 // scripts/build.py
            guard params.registerPrices.count == 5, params.renewPrices.count == 5,
                  (params.registerPrices + params.renewPrices).allSatisfy({ $0 <= priceCap }),
                  params.maxYears >= 1, params.maxYears <= 31,
                  params.periodMs >= 60_000, params.periodMs <= yearMs, params.maxYears * params.periodMs < 1_000_000_000_000,
                  params.renewWindowMs > 0, params.renewWindowMs <= params.periodMs else {
                throw Failure("manifest: params out of range")
            }
            guard params.registerPrices == Self.pinnedRegisterPrices, params.renewPrices == Self.pinnedRenewPrices else {
                throw Failure("manifest: the price tables are not the ones the pinned gap and name bake")
            }
            guard genesisState.lo == zero32, genesisState.hi == ff32 else { throw Failure("manifest: genesis gap is not (00..00, ff..ff)") }
            let gapScript = gap.script(Codec.gapState(lo: zero32, hi: ff32))
            guard genesisOutput.script == gapScript, genesisOutput.scriptVersion == 0 else {
                throw Failure("manifest: genesis output is not the genesis gap of these templates")
            }
            guard genesisOutput.value == params.gapValue else { throw Failure("manifest: genesis gap value") }
            let id = Codec.covenantId(outpoint: genesisOutpoint, authorized: [(0, genesisOutput)])
            guard id == registryCovenantId else {
                throw Failure("manifest: registry id \(hex(registryCovenantId)) != covenant_id(genesis) \(hex(id))")
            }
        }
    }
}
