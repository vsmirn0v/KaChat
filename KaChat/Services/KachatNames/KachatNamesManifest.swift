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

    /// The registry parameters (params/testnet10.json), identical on testnet-10 and mainnet.
    struct Params: Equatable {
        let bond: UInt64
        let gapValue: UInt64
        let tCommit: UInt64
        let maxYears: Int64
        let graceMs: Int64
        /// `renew` is valid from `expiresAt - renewWindowMs` on (registry v2; 10 days)
        let renewWindowMs: Int64
        /// sompi per year for names of 1, 2, 3, 4, 5+ bytes
        let prices: [UInt64]
        let renewPrices: [UInt64]
        let offerMaxFee: UInt64

        func price(forLength n: Int) -> UInt64 { prices[Codec.tier(n)] }
        func renewPrice(forLength n: Int) -> UInt64 { renewPrices[Codec.tier(n)] }

        // MARK: The paid period (registry v2, KACHAT_NAMES.md 4.1; ops.rs)

        /// The most years `extend` can add now: a period (from `periodStart`) holds at most
        /// `maxYears` (ops.rs `extendable_years`).
        func extendableYears(periodStart: Int64, expiresAt: Int64) -> Int64 {
            let room = periodStart + maxYears * KachatNames.yearMs - expiresAt
            return room < 0 ? 0 : min(room / KachatNames.yearMs, maxYears)
        }

        func extendableYears(_ f: NameFields) -> Int64 { extendableYears(periodStart: f.periodStart, expiresAt: f.expiresAt) }

        /// When `renew` becomes valid: `expiresAt - renewWindowMs` (unix ms). The transaction is
        /// final once the network's past median time passes its lock time, which is at least this.
        func renewOpens(expiresAt: Int64) -> Int64 { expiresAt - renewWindowMs }
    }

    /// The deployment manifest `kachat-names-<network>.json` (written by the kachat-domains CLI's
    /// `genesis`, served by the indexer at `GET /names/manifest`): params, every contract's prefix,
    /// suffix, template hash and dispatch tags, the registry covenant id and the genesis binding.
    /// `verify()` must pass before anything trusts it.
    struct Manifest {
        static let supportedNetwork = "testnet-10"
        static let bundleResource = "kachat-names-testnet-10"

        /// Template hashes of the pinned build - registry v2 (silverc v1.0.0 @ 3ed9733), the same
        /// on every network (kachat-domains README "Sizes and template hashes"). The offer bakes
        /// the registry id, so it is checked against the id instead.
        static let pinnedTemplateHashes: [String: String] = [
            "KachatGap": "182c463cf59f6d175f75339e4efc75d2065e8e7bb8dcc515e4769d3ff805dd46",
            "KachatName": "e8ded947687947b565e10cbf6e6fec60e5c90cf992c7bce2298e6dce8db29d16"
        ]
        /// The registry v1 build (117-byte name state, no `extend`, no renewal window), which the
        /// first testnet-10 genesis runs. Recognised only to say "outdated", never trusted.
        static let v1TemplateHashes: [String: String] = [
            "KachatGap": "a182d59bbf460baff5ec99ca850b990d45fbafee4dfbe9a3a7a1afe21e7ba8ca",
            "KachatName": "42eddf19e7ea2bc78b9aa97937f21be0505ebcf964653508f74e179dd6c7e39d"
        ]
        static let stateLengths: [String: Int] = ["KachatGap": 66, "KachatName": 126, "KachatOffer": 75]
        static let entries: [String: [String]] = [
            "KachatGap": ["register", "merge", "absorbed"],
            "KachatName": ["transfer", "list", "buy", "extend", "renew", "release", "reclaim"],
            "KachatOffer": ["accept", "withdraw", "refund"]
        ]

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

        init(json root: [String: Any]) throws {
            network = try Self.str(root["network"], "network")
            status = (root["status"] as? String) ?? ""
            guard let p = root["params"] as? [String: Any] else { throw Failure("manifest: params missing") }
            // a registry v1 manifest (no renewal window, 117-byte name state) describes contracts
            // this app no longer builds for: it waits for the v2 genesis
            if p["renewWindowMs"] == nil
                || ((root["artifacts"] as? [String: Any])?["KachatName"] as? [String: Any])?["templateHash"] as? String
                    == Self.v1TemplateHashes["KachatName"] {
                throw Failure.outdatedRegistry
            }
            params = Params(
                bond: try Self.u64(p["bond"], "bond"),
                gapValue: try Self.u64(p["gapValue"], "gapValue"),
                tCommit: try Self.u64(p["tCommit"], "tCommit"),
                maxYears: Int64(try Self.u64(p["maxYears"], "maxYears")),
                graceMs: Int64(try Self.u64(p["graceMs"], "graceMs")),
                renewWindowMs: Int64(try Self.u64(p["renewWindowMs"], "renewWindowMs")),
                prices: try Self.tiers(p["prices"], "prices"),
                renewPrices: try Self.tiers(p["renewPrices"], "renewPrices"),
                offerMaxFee: try Self.u64(p["offerMaxFee"], "offerMaxFee")
            )
            guard let artifacts = root["artifacts"] as? [String: Any] else { throw Failure("manifest: artifacts missing") }
            gap = try Self.template(artifacts, "KachatGap")
            name = try Self.template(artifacts, "KachatName")
            offer = try Self.template(artifacts, "KachatOffer")
            registryCovenantId = try unhex32(try Self.str(root["registryCovenantId"], "registryCovenantId"))
            guard let g = root["genesis"] as? [String: Any] else { throw Failure("manifest: genesis missing") }
            genesisTxid = try unhex32(try Self.str(g["txid"], "genesis.txid"))
            let op = try Self.str(g["outpoint"], "genesis.outpoint").split(separator: ":")
            guard op.count == 2, let idx = UInt32(op[1]) else { throw Failure("manifest: genesis.outpoint") }
            genesisOutpoint = Outpoint(txid: try unhex32(String(op[0])), index: idx)
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
        /// suffix, the gap and name ones equal to the pinned build; every dispatch tag present;
        /// the offer baked for this registry id and name template; the genesis output is the
        /// genesis gap `(00..00, ff..ff)` worth `gapValue`; and
        /// `registryCovenantId == covenant_id(genesis outpoint, [(0, genesis gap)])`.
        func verify() throws {
            guard network == Self.supportedNetwork else {
                throw Failure("manifest is for \(network); only \(Self.supportedNetwork) is enabled (mainnet waits for an audit)")
            }
            for t in [gap, name, offer] {
                guard Codec.templateHash(prefix: t.prefix, suffix: t.suffix) == t.templateHash else {
                    throw Failure("manifest: \(t.contract) template hash does not match its prefix and suffix")
                }
                if let pinned = Self.pinnedTemplateHashes[t.contract], hex(t.templateHash) != pinned {
                    if Self.v1TemplateHashes[t.contract] == hex(t.templateHash) { throw Failure.outdatedRegistry }
                    throw Failure("manifest: \(t.contract) is not the pinned build")
                }
                for e in Self.entries[t.contract] ?? [] where t.dispatchTags[e] == nil {
                    throw Failure("manifest: \(t.contract) dispatch tag for \(e) missing")
                }
            }
            guard offer.suffix.range(of: registryCovenantId) != nil, offer.suffix.range(of: name.templateHash) != nil else {
                throw Failure("manifest: the offer is not built for this registry id and name template")
            }
            guard params.prices.count == 5, params.renewPrices.count == 5, params.maxYears >= 1, params.maxYears <= 31,
                  params.renewWindowMs > 0, params.renewWindowMs < yearMs else {
                throw Failure("manifest: params out of range")
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
