> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# gRPC Endpoint Pool Design

## Problem Statement

Current pool design is not resilient to failing endpoints. Example: `kaspa.aspectron.org` responds on TCP port 16110 but times out on gRPC requests. This causes:
- Slow pool refreshes (waiting for timeouts)
- Poor UX when app tries to use unresponsive endpoints
- No isolation of misbehaving nodes

## Solution: Three-Tier Pool Architecture

Split endpoints into Hot, Warm, and Cold pools with automatic promotion/demotion based on health checks.

```
┌─────────────────────────────────────────────────────────────┐
│                         COLD POOL                           │
│  Discovery source, unchecked endpoints, failed endpoints    │
│  Max size: 500 endpoints                                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ (pass health checks)
┌─────────────────────────────────────────────────────────────┐
│                         WARM POOL                           │
│  Validated candidates ready for hot pool promotion          │
│  Target size: 30 endpoints                                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ (lowest latency)
┌─────────────────────────────────────────────────────────────┐
│                         HOT POOL                            │
│  Active endpoints for user requests                         │
│  Target size: 5 endpoints                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Endpoint Data Structure

Each endpoint stores:

| Field | Type | Description |
|-------|------|-------------|
| `url` | String | Full URL with protocol, host, port (e.g., `grpc://host:16110`) |
| `pool` | Enum | Current pool: `.hot`, `.warm`, `.cold` |
| `latencyMs` | Int? | Last measured gRPC ping latency |
| `errorCount` | Int | Cumulative errors (preserved across pool transitions) |
| `coolingUntil` | Date? | Don't recheck until this time |
| `lastDaaScore` | UInt64? | Last observed DAA score |
| `peerSeenDate` | Date? | Last seen in getPeerAddresses response |
| `lastSuccessDate` | Date? | Last successful request |
| `lastCheckDate` | Date? | Last health check attempt |
| `manualFlag` | Enum | Origin: `.dynamic`, `.userAdded`, `.preProvisioned` |
| `networkType` | Enum | `.mainnet` or `.testnet` |

### Manual Flag Values

| Value | Description | Can Delete | Behavior on Reset |
|-------|-------------|------------|-------------------|
| `.dynamic` (0) | Discovered via peer discovery | Yes | Removed |
| `.userAdded` (1) | Manually added by user | Yes | Removed |
| `.preProvisioned` (2) | Bundled with app | Yes | Restored |

---

## Health Checks

All pool promotions require passing health checks. Use gRPC `pingRequest` for latency measurement everywhere (TCP ping is unreliable - some nodes pass TCP but fail gRPC).

### Required Checks

| Check | RPC Call | Pass Criteria |
|-------|----------|---------------|
| Capabilities | `getInfoRequest` | `isUtxoIndexed=true` AND `isSynced=true` |
| Metrics | `getMetricsRequest` | Response received (validates node version) |
| DAA Score | `getMetricsRequest` | Within 10,000 of reference DAA* |
| Latency | `pingRequest` | Response received, latency recorded |

*Reference DAA: Use `https://api.kaspa.org/info/blockdag` or cross-validate between hot pool nodes (majority consensus). If unavailable, log warning and pass check.

### Check Timeout

- **Cold pool endpoints:** 5 seconds
- **Hot/Warm pool endpoints:** 15 seconds (extended timeout - they deserve more patience)

---

## Network Awareness

The pool manager monitors device network status:

1. **Offline detection:** No health checks when device is offline
2. **Network change grace period:** Ignore connection errors within 5 seconds of network change (wifi/cellular switch)
3. **Automatic resume:** Background refresh resumes when network becomes available

---

## Pool Rules

### Hot Pool (Active Endpoints)

**Purpose:** Endpoints actively used for user requests (payments, messages, subscriptions).

**Target size:** 5 endpoints
**Error threshold:** 3 errors before demotion to warm

**Rules:**
1. Connection failure → increment `errorCount`, demote to Warm only after 3 errors
2. If count < 5 → promote lowest-latency endpoints from Warm pool
3. If count > 5 after successful recheck → demote highest-latency endpoints to Warm pool
4. Successful request → reset `errorCount` to 0
5. When `coolingUntil` reached → run background health checks (does NOT interrupt active connections)

**Cooling time on success:** 10 minutes + random(1-10 minutes)

**Connection selection:**
- Cooling time is NOT used to exclude endpoints from connection selection
- Only `errorCount >= 3` excludes endpoint from selection
- Endpoints are sorted by: fewer errors first, then lower latency
- All hot pool endpoints are tried before warm pool

**Failover behavior:**
- On request failure, immediately retry with next hot pool endpoint
- If all hot endpoints fail, try ALL warm pool endpoints (not just top 3)
- If all fail, try top 10 cold pool endpoints (not in cooling)
- Only after all exhausted, trigger emergency pool refresh

---

### Warm Pool (Ready Candidates)

**Purpose:** Pre-validated endpoints ready for hot pool promotion. Also serves as circuit-breaker buffer for demoted hot pool endpoints.

**Target size:** 30 endpoints (can exceed temporarily when receiving demotions)
**Error threshold:** 5 errors before demotion to cold

**Rules:**
1. If count < 30 → discover and validate endpoints from Cold pool
2. Endpoints must pass all health checks to enter Warm pool
3. Sort by: fewer errors first, then lower latency (for hot pool promotion candidates)
4. Successful health check → reset `errorCount` to 0

**Cooling time on success:** 30 minutes + random(1-30 minutes)

---

### Cold Pool (Discovery Source)

**Purpose:** Store all known endpoints, including failed ones with cooling periods.

**Maximum size:** 500 endpoints (LRU eviction based on `peerSeenDate`)

**Pre-provisioned endpoints (bundled with app):**
```
grpc://n.seeder1.kaspad.net:16110
grpc://n.seeder2.kaspad.net:16110
grpc://n.seeder3.kaspad.net:16110
grpc://n.seeder4.kaspad.net:16110
grpc://kaspa.aspectron.org:16110
grpc://mainnet-dnsseed.kas.pa:16110
grpc://mainnet-dnsseed-1.kaspanet.org:16110
grpc://mainnet-dnsseed-2.kaspanet.org:16110
grpc://n-mainnet.kaspa.ws:16110
```

**Rules:**
1. Failed endpoints get cooling time based on error count (exponential backoff)
2. Don't recheck endpoints where `coolingUntil > now`
3. Pre-provisioned endpoints: shorter cooling (max 5 minutes), never deleted

**Cooling time formula:**
```
Regular endpoints:    min(1 week, 10 min * 2^errorCount) + random(0-10 min)
Pre-provisioned:      min(5 min, 1 min * 2^errorCount) + random(0-1 min)
```

---

## Peer Discovery

Run from hot pool nodes using `getPeerAddresses` RPC.

**Process:**
1. Call `getPeerAddresses` on hot pool endpoints with `errorCount == 0` only
2. Update `peerSeenDate` for all matching endpoints in all pools
3. Deduplicate by host:port
4. Filter out: IPv6, private subnets (10.x, 192.168.x, 172.16-31.x, 127.x)
5. Convert P2P port to gRPC port (mainnet: 16110, testnet: 16210)
6. Add new endpoints to Cold pool if not already present
7. If discovery fails for an endpoint, record error (prevents immediate retry)

**Trigger conditions:**
- Hot or Warm pool exhausted of working endpoints
- Any hot/warm endpoint has `peerSeenDate` older than 2 days
- User manually triggers refresh

**Settings toggle:** "Discover new peers" (enabled by default)
- When disabled, only use pre-provisioned and user-added endpoints

---

## Quick Boot Procedure

**Trigger:** App startup when Hot and Warm pools are empty.

**Process:**
1. Start quick boot in background (non-blocking)
2. Check Cold pool endpoints in parallel (limit concurrency to 50)
3. Run full health checks (capabilities, DAA score, latency)
4. **Immediately** promote each passing endpoint to Hot pool as it completes (don't wait for all)
5. RPC manager waits up to 10s for first hot endpoint, then starts connecting
6. Excess endpoints (>5) will be pruned by normal hot pool rules after boot completes

**Goal:** Minimize time to first usable connection on fresh install. First working endpoint is available within ~1s typically.

---

## Full Pool Refresh

**Trigger:** User manually triggers refresh, or emergency refresh after all pools exhausted.

**Process:**
1. Discover new peers from existing hot pool endpoints (with 0 errors)
2. Check all non-cooling endpoints in parallel batches
3. **Keep current pool status** during checks (hot pool stays populated!)
4. As results arrive:
   - Pass: Promote to hot pool, then rebalance (best 5 stay, rest move to warm)
   - Fail: Demote to cold pool, increment error count
5. After all checks complete, rebalance warm pool (keep best 30, move excess to cold)

**Important:** Endpoints are NOT reset to cold at the start. This ensures the app always has working hot pool endpoints during refresh.

**Promotion rules:**
1. All passing endpoints are promoted to hot pool immediately
2. After each promotion, hot pool is rebalanced:
   - Sort by: fewer errors first, then lower latency
   - Keep best 5 in hot pool
   - Move excess to warm pool
3. At end of refresh, warm pool is rebalanced (keep best 30, move excess to cold)

This ensures the best endpoints are always in hot pool, even if a slower endpoint was discovered first.

**Goal:** Provide working endpoints throughout refresh, never leave hot pool empty.

---

## Connection Wrapper

All gRPC calls go through a connection wrapper that handles pool management automatically.

**Responsibilities:**
1. Select best available endpoint (sorted by: fewer errors, then lower latency)
2. On failure, immediately failover to next endpoint, **excluding the failing URL**
3. Track success/failure, trigger pool transitions
4. If all hot endpoints fail:
   - Try ALL warm pool endpoints (not just top 3)
   - Try top 10 cold pool endpoints (not in cooling)
   - If still failing, trigger emergency pool refresh
   - Surface error to UI only after all options exhausted

**Failover behavior:**
- Failing endpoint URL is captured before disconnect
- Passed to connect() as `excludeUrl` parameter
- Prevents retry loops where same broken endpoint is selected repeatedly

**Retry strategy:**
```
Hot pool:  immediate failover, no delay between attempts
Warm pool: immediate failover for all endpoints
Cold pool: try top 10 not in cooling
Refresh:   only after all pools exhausted
```

---

## Background Operations

### Periodic Health Checks
- Check endpoints where `coolingUntil <= now`
- Run in background, don't block user requests
- Batch checks to avoid resource exhaustion (max 5 concurrent)

### Periodic Persistence
- Save pool state every 5 minutes
- Save on app background/terminate
- Save after significant pool changes (>3 transitions)

### Peer Discovery Cycle
- Run every 2 hours if peer discovery enabled
- Also triggered when hot pool drops below 3 endpoints

---

## UI Requirements

### Connection Settings

1. **Pool Statistics Display:**
   - Hot pool: X endpoints (avg latency: Yms)
   - Warm pool: X endpoints
   - Cold pool: X endpoints
   - Last refresh: timestamp

2. **Endpoint List:**
   - Show all endpoints grouped by pool
   - Display: URL, latency, error count, status, manual flag
   - Allow manual add/remove
   - "Reset to defaults" button (restores pre-provisioned, clears dynamic)

3. **Toggles:**
   - "Discover new peers" (default: on)
   - "Show detailed pool info" (default: off)

4. **Actions:**
   - "Refresh pools now" button
   - "Clear all dynamic endpoints" button

---

## Implementation Phases

| Phase | Task | Files |
|-------|------|-------|
| 1 | Data structures, migrate existing pool | `Models.swift`, `GrpcEndpointPoolManager.swift` |
| 2 | Pool manager actor with hot/warm/cold logic | `GrpcEndpointPoolManager.swift` |
| 3 | Health check methods (getInfo, getMetrics, ping) | `GrpcEndpointPoolManager.swift`, `KaspaGRPCClient.swift` |
| 4 | Connection wrapper with auto-failover | `GrpcConnectionWrapper.swift` (new) |
| 5 | Quick boot procedure | `GrpcEndpointPoolManager.swift` |
| 6 | Background refresh cycles | `GrpcEndpointPoolManager.swift` |
| 7 | Settings UI updates | `SettingsView.swift` |
| 8 | Peer discovery toggle | `SettingsView.swift`, `Models.swift` |
