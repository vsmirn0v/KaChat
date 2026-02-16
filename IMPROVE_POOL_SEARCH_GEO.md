# Improve Pool Search with Geo-Aware Low-Latency Ranking

## Goals
- Improve discovery and promotion speed for low-latency nodes.
- Reduce expensive gRPC probes on weak candidates.
- Add persistent network-neighborhood learning so new nodes in known-fast areas are prioritized.
- Introduce optional geo-aware distance signal (soft prior, never a hard gate).

## Scope (1-7)
1. Add a pre-ranking layer before deep probe:
   - Use TCP reachability + TCP RTT + neighborhood history + optional geo distance.
2. Add local IP intelligence storage:
   - Persist per-node geo/asn/prefix hints and derived predicted RTT floor.
3. Resolve client public-IP context once per 24h:
   - Cache result and use as reference for distance-based priors.
   - Fallback to best-known pool hints if unavailable.
4. Combine signals into one candidate ranking score:
   - Reliability and measured RTT are dominant.
   - Geo and neighborhood signals are additive soft boosts/penalties.
   - Keep exploration slice to avoid local minima.
5. Learn by network neighborhood:
   - Track prefix-level performance and success trends.
   - Favor candidates from historically fast/reliable prefixes.
6. Progressive probing:
   - Stage A: short-timeout TCP screening over broader set.
   - Stage B: confirm promising subset with normal timeout and retries.
   - Stage C: full gRPC probing on survivors ranked by composite score.
7. Discovery source diversification:
   - Use multiple discovery sources per cycle based on pool health.
   - Increase target successful discovery calls when degraded/critical.

## Concrete Code Changes

### Node Model
- Extend `NodeProfile` to persist geo/network intelligence:
  - `asn`, `countryCode`, `prefix24`, `geoLatitude`, `geoLongitude`,
    `geoDistanceKm`, `predictedMinRttMs`, `geoResolvedAt`.
- Extend `NodeHealth` with TCP RTT memory:
  - `tcpConnectRttMs` (EWMA) + `lastTcpRttMs`.

### Registry
- Extend TCP update API:
  - `updateTcpPingResult(..., rttMs:)` and update EWMA when available.
- Add neighborhood analytics helper:
  - Build aggregated prefix stats from current persisted records.

### Profiler
- Add ranking context:
  - Prefix stats + optional client geo context + exploration budget.
- Candidate pre-ranking in `calculateProbePriority`.
- Add progressive TCP screening pipeline:
  - Short timeout sweep, then confirm subset.
- Geo enrichment pipeline:
  - Resolve/store prefix and optional geo hints.
  - Refresh client public-IP context every 24h.
- Discovery optimization:
  - Dynamic `targetSuccesses` and `sourceParallelism` by pool health and quality.

## Guardrails
- Geo is a soft signal only; never exclude nodes purely by distance.
- Maintain random exploration slice (10-20%).
- Keep changes backward-compatible with missing geo database (signals simply absent).

## Validation
- Build compile check for modified files.
- Runtime verification logs:
  - ranking context activation
  - staged screening pass rates
  - discovery source fanout and success counts
  - candidate promotion latency improvement

## Dataset Operations
- **Source**: DB-IP Lite (CC BY 4.0, https://db-ip.com) via sapics/ip-location-db.
- **Attribution required**: "IP Geolocation by DB-IP" in app About/Licenses screen.
- Bundled file: `KaChat/Resources/geoip-lite.json` (~52K /16 entries, 4.8 MB, 86% public IPv4 coverage).
  - Fields per entry: `cidr`, `latitude`, `longitude`, `country_code`, `asn`.
  - Aggregated from 3.2M city rows + 392K ASN rows to /16 blocks (weighted average lat/lon, majority country).
- Build/update script: `scripts/build_geoip_lite.py`
  - Auto-downloads DB-IP Lite City + ASN CSVs, or accepts local CSV paths.
  - `python3 scripts/build_geoip_lite.py --output KaChat/Resources/geoip-lite.json`
