# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KaChat is a native iOS messaging and payment application built on the Kaspa blockchain. It enables encrypted peer-to-peer messaging with on-chain payments using SwiftUI.

## Build Commands

Important, never build yourself, always ask user to build.

```bash
# Open project in Xcode
open KaChat.xcodeproj

# Build from command line
xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests
xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'platform=iOS Simulator,name=iPhone 17' test

# Clean build
xcodebuild -project KaChat.xcodeproj -scheme KaChat clean
```

## Architecture

### MVVM Pattern with Singleton Services

The app uses MVVM architecture with global singleton services injected via SwiftUI's `@EnvironmentObject`:

- **Entry Point**: `KaChatApp.swift` initializes all services as `@StateObject` and injects them into the view hierarchy
- **Services**: Singleton pattern (`*.shared`) for core business logic, all marked `@MainActor` for thread safety
- **ViewModels**: `@ObservableObject` classes that bridge services and views
- **Views**: Pure SwiftUI views organized by feature (Chat, Contacts, Onboarding, Settings)

### Key Services

| Service | Purpose |
|---------|---------|
| `WalletManager` | Wallet lifecycle, key derivation, balance tracking |
| `ChatService` | Message polling, conversation state, sync with indexer |
| `NodePoolService` | Main entry point for gRPC node pool (POOLS_v2 architecture) |
| `NodeRegistry` | Persistent node storage with health/profile tracking |
| `NodeSelector` | Capability-aware node selection with scoring |
| `NodeProfiler` | Node discovery, DNS resolution, health probing |
| `GRPCConnectionPool` | Manages gRPC connections with circuit breakers |
| `UtxoSubscriptionManager` | UTXO subscriptions with failover and keepalive |
| `KasiaAPIClient` | REST HTTP client for Kasia Indexer |
| `KeychainService` | Device-specific Secure Enclave credential storage |
| `MessageStore` | Core Data message persistence, device-local, one SQLite store per wallet |
| `ContactsManager` | Address book persistence, KNS domain integration |
| `KNSService` | Kaspa Name Service API client for domain resolution |
| `KasiaTransactionBuilder` | Constructs signed Kaspa transactions |
| `ChessTournamentService` | Chess tournaments: watches `#chess-arena` through `PublicChatService`, reduces it with `ChessTournamentEngine` (pure, deterministic - the indexer ports it), sends create/join/move/resign/claim/chat as broadcast transactions. Views in `Views/Chess/` |
| `CallService` | Voice/video calls over Nextcloud Talk + WebRTC (`NextcloudTalkClient`, `WebRTCClient`, `CallView`); ringing rides the 1:1 chat as `call_*` envelopes. `CallKitManager` mirrors every call into CallKit (lock-screen ringing, Recents, system audio session); `VoIPPushManager` receives the PushKit VoIP push the caller's phone requests from the push service so a closed app rings |

### Messaging Protocol

1. **Handshake**: Initial key exchange, stored in sender's self-stash on-chain
2. **Contextual Messages**: Encrypted messages using shared secret derived from handshake
3. **Payments**: On-chain KAS transfers with optional encrypted metadata
4. **Audio**: Voice messages encoded with the Opus codec (vendored `Opus.xcframework` via `OpusBridge`)

### Network Communication

- **Kaspa Node (gRPC)**: Managed by `NodePoolService` (`NodePool/*`) for UTXO subscriptions, transaction submission, and peer discovery
- **Kaspa REST API**: Configurable via Settings (default: `api.kaspa.org` mainnet / `api-tn11.kaspa.org` testnet) for fetching transaction history, payments, and UTXO fallback
- **Kasia Indexer (REST)**: Configurable via Settings (default: `indexer.kasia.fyi`) for message indexing and retrieval
- **KNS API**: Configurable via Settings (default: `api.knsdomains.org`) for Kaspa Name Service domain resolution

### Connection Settings

All network endpoints are configurable in Settings > Connection Settings:
- **Network**: mainnet / testnet toggle
- **Indexer URL**: Kasia message indexer endpoint
- **KNS URL**: Kaspa Name Service API endpoint
- **Kaspa REST API URL**: Block explorer API for transaction lookups

Settings are stored in `AppSettings` struct with network-specific defaults and loaded via `AppSettings.load()` static method (safe to call from any context).

### KNS (Kaspa Name Service) Integration

The app integrates with KNS to provide human-readable domain names for contacts:

**Features:**
- Resolve KNS domains (e.g., `alice.kas`) to Kaspa addresses when adding contacts
- Display KNS domains on contact cards in chat list
- Show all domains owned by a contact in Chat Info view
- Auto-set contact alias to primary KNS domain when not manually set

**API Endpoints:**
- `GET /api/v1/{domain}/owner` - Resolve domain to owner address (forward lookup)
- `GET /api/v1/primary-name/{address}` - Get primary domain for address (reverse lookup)
- `GET /api/v1/assets?owner={address}&type=domain` - Get all domains owned by address

**Key Components:**
- `KNSService` - API client with caching for domain lookups
- `KNSAddressInfo` - Cached info about domains for an address
- `KNSDomainResolution` - Result of forward domain resolution
- `ContactsManager.fetchKNSDomainsForAllContacts()` - Batch fetch for all contacts

### Data Sync Strategy

The app uses a subscription-based approach to minimize polling:

1. **Initial Sync**: Full fetch of historical data on startup/wallet import
2. **gRPC Subscriptions**: Subscribe to `utxosChanged` for real-time payment notifications
3. **Fallback Polling**: If subscription fails, fall back to periodic polling until reconnected
4. **Adaptive per-object cursors** for handshakes/contextual messages:
   - Store `lastFetchedBlockTime` per sync object (handshake in/out, contextual alias in/out)
   - If last fetched block is within 10 minutes of current sync: rewind cursor by 10 minutes for reorg safety
   - If last fetched block is older than 10 minutes: use `lastFetchedBlockTime + 1` to avoid repeatedly downloading the same old window
   - Keep `lastPollTime` as a global fallback for first-time objects and migration safety

Payment detection logic:
- **Incoming**: Our address appears in outputs but NOT in inputs
- **Outgoing**: Our address appears in inputs (we're the sender)
- Amount for incoming = sum of outputs to our address
- Amount for outgoing = output amount to recipient (non-change output)

### Live Message Delivery (1:1 chats)

Four independent, idempotent paths surface an incoming 1:1 message; all insert through
`ChatService.addMessageToConversation`, which dedupes by `txId` at both the fetch and the
conversation level, so overlap is harmless:

1. **gRPC `utxosChanged` subscription** (`UtxoSubscriptionManager`) on own + contacts' addresses.
   This is server-side state on the gRPC stream and dies with it. `GRPCStreamConnection` bumps
   `connectionGeneration` on every connect; the manager records the generation at subscribe time
   and re-sends `notifyUtxosChangedRequest` when it moved (15s health check +
   `verifyPrimarySubscription()` right after foreground reconnect), then posts
   `.rpcSubscriptionsRestored` so `ChatService` runs a catch-up sync for the dead window.
2. **Open-chat poll** (`startActiveChatPoll`, ~2s) for the conversation on screen only.
3. **Foreground contact sweep** (`startForegroundContactSweep`): runs only while the UTXO
   subscription is down or not verified alive within 45s (`isUtxoSubscriptionHealthy`), 30s
   between sequential sweeps (60s on cellular, backs off to 120s on indexer errors), 120ms
   between contacts, a window of 12 per pass: the 4 most recent contacts every pass plus a
   rotating slice of the rest. Starts on app-active / wallet load, stops on background /
   wallet switch / logout. Its loop also carries the group catch-up ride-along.
4. **Remote push** (`PushNotificationManager`) and the **60s fallback poll**
   (`startFallbackPolling`), which runs only when the subscription is down and push is off.

There is NO per-contact "realtime disabled" flag, spam detector, or per-contact 60s poll in the
code (`realtimeUpdatesDisabled`, `noisyContactWarning`, `recordIrrelevantTxNotification` do not
exist on any platform). Earlier docs described that feature; it was never built.

### gRPC Node Pool (POOLS_v2)

The app uses a sophisticated gRPC-based node pool architecture (see `POOLS_v2.md` for full design):

**Node Discovery (`NodeProfiler`):**
- Resolves DNS seeds using `getaddrinfo()` for all A records
- Discovers peers via `getPeerAddresses` from active nodes
- Filters by an allowlist of gRPC ports (15110/15111/16110/16111 mainnet family, 15210/15211/16210/16211 testnet family; see `NodeProfiler.allowedGrpcPorts`)

**Dynamic Probe Modes:**
- **Aggressive mode**: Fast probing (10s loop, 4min candidate interval) when pool is building
- **Conservative mode**: Slow probing (60s loop, 60min candidate interval) when pool is healthy
- Triggers conservative when: 5+ active nodes AND at least one with latency <200ms

**Discovery Pause:**
- Pauses discovery and candidate probing when pool is healthy enough:
  - 5+ nodes with latency ≤200ms, OR
  - 15+ total active nodes
- Resumes automatically when criteria no longer met

**UTXO Subscriptions (`UtxoSubscriptionManager`):**
- Sticky primary + warm standby pattern
- 30-second keepalive ping (`getInfoRequest`) on subscription channel
- Automatic failover with state resync via `GetUtxosByAddresses`
- Triggers catch-up sync on restart/reconnect unless remote push channel is currently marked reliable (then debounced)

**Robustness:**
- **Network Epochs**: Health stats reset on network path changes (WiFi↔cellular, VPN)
- **Circuit Breakers**: Per-connection failure tracking with automatic recovery
- **Hedged Requests**: Race primary + backup for user-facing operations
- **REST Fallback**: `getUtxosByAddresses()` falls back to REST API when gRPC unavailable

### Push Notifications (Implemented)

Remote push notifications are implemented for background/terminated delivery. `PushNotificationManager` manages token lifecycle and indexer registration; `KaChatNotificationService` decrypts notification payloads when available.

**Key Points:**
- Requires fork of `kasia-indexer` with `PushNotificationActor`
- Devices register watched addresses (contacts) with indexer
- Push includes encrypted payload (≤3.5KB) for immediate decryption, or txId-only for large messages
- iOS Notification Service Extension (`KaChatNotificationService`) decrypts and displays actual message content
- App Group (`group.com.kachat.app`) shares keys/contacts between main app and extension
- Push reliability is scored by txId correlation between UTXO-notified incoming messages and APNs receipt:
  - 3 consecutive misses (after 60s grace each) -> `unreliable`, force re-register + immediate catch-up sync
  - First matched hit -> `reliable` again
  - When `reliable`, app-active/restart catch-up syncs are debounced (10 minutes)

### Data Storage

- **Keychain + Secure Enclave**: Seed phrases and private keys wrapped with device-specific SE keys (see Multi-Device section)
- **Core Data (local only)**: Messages in a plain `NSPersistentContainer`, one SQLite store per wallet. No iCloud/CloudKit anywhere in the app - the only cross-device channel is the encrypted Nextcloud archive (`NextcloudService`)
- **UserDefaults**: Settings, contact aliases (fallback for wallet)

### Multi-Device Architecture

A seed can be entered on several devices; each keeps its own local message store, and the encrypted Nextcloud archive (Settings > Storage > Nextcloud, Automatic Sync) is what carries history between them. The app never uses iCloud or CloudKit - removed in 4.1 - so there is no iCloud container entitlement and nothing about a wallet reaches Apple.

**Bundle Identifiers:**
- Bundle ID: `com.kachat.app`
- App Group: `group.com.kachat.app`
- Keychain Access Group: `$(AppIdentifierPrefix)com.kachat.app`

**Device-Specific Secure Enclave Storage (`KeychainService`):**

Seed phrases and private keys are encrypted using the device's Secure Enclave, making them non-transferable between devices:

```swift
// Device ID derived from SE public key hash (first 8 bytes)
let seKey = try secureEnclavePrivateKey()
let publicKeyData = SecKeyCopyExternalRepresentation(publicKey)
let deviceId = SHA256.hash(data: publicKeyData).prefix(8).hexString  // e.g., "a1b2c3d4e5f6g7h8"

// Keychain keys are device-specific
"kachat_seed_phrase.a1b2c3d4e5f60718"  // Device 1
"kachat_seed_phrase.29e8f7a6b5c4d3e2"  // Device 2
```

- Each device must enter the seed phrase separately during setup
- SE-wrapped data cannot be decrypted on other devices
- `hasSeedPhrase()` and `hasPrivateKey()` check for device-specific keys

**Per-Wallet Stores (`MessageStore`):**

Messages are partitioned by wallet address using separate SQLite files:

```swift
// SQLite file per wallet, suffix = SHA256(walletAddress).prefix(8) hex
"KasiaMessages-a1b2c3d4.sqlite"  // Wallet 1
"KasiaMessages-e5f6g7h8.sqlite"  // Wallet 2
```

- Switching wallets reloads the appropriate message store
- All Core Data queries filter by `walletAddress` field
- Persistent history tracking stays enabled on the store (Core Data refuses to open a store that had it and lost it); `purgeOldHistory()` trims it on every load

## Code Organization

```
KaChat/
├── App/              # KaChatApp, ContentView (router), LaunchRouter, MainTabView
├── Models/           # Models.swift (core), PortfolioModels.swift, SwapModels.swift
├── ViewModels/       # SettingsViewModel, PortfolioViewModel
├── Views/            # SwiftUI views by feature: Chat/, Contacts/, Onboarding/, Settings/,
│                     # ColdStorage/, KaPosts/, Portfolio/, Swap/, Shared/
├── Services/         # Core business logic, API clients, crypto utilities (+ NodePool/)
├── Shortcuts/        # App Intents / Shortcuts integration
├── Generated/        # Generated protobuf/gRPC sources
└── Utilities/        # CryptoUtils, KasiaCipher (ECIES, in KaChatCipher.swift), Bech32, ...
```

Companion targets at the repo root: `KaChatNotificationService/` (push decryption extension), `KaChatShareExtension/` (share sheet), `KaChatWidgets/` (home screen widgets), `KaChatIntents/` (Intents extension: `INStartCallIntent` so the Contacts app, Siri and Recents can "call with KaChat"; it resolves against `call_contacts` in the App Group and hands the call to the app).

## Key Dependencies

- **P256K** (swift-secp256k1, SPM): secp256k1 elliptic curve library for key derivation and signing
- **grpc-swift + SwiftProtobuf** (SPM): gRPC stack for the node pool (`KaChat/Generated/*` holds the generated protobuf/gRPC sources)
- **Opus** (`external/opus/Opus.xcframework`, vendored): audio codec for voice messages, linked through the Objective-C bridge `OpusBridge.h/m`

## Patterns to Follow

- Mark all service classes and view models with `@MainActor` for UI thread safety
- Use async/await for all asynchronous operations
- Error handling via `KasiaError` enum with `LocalizedError` conformance
- Kaspa addresses use Bech32 encoding with `kaspa:` or `kaspatest:` prefix
- Amounts are in sompi (1 KAS = 100,000,000 sompi)

## UI Patterns

### Send Mode Menu (ChatDetailView)

The send button supports multiple modes (message, payment, audio) via a drag-to-select menu:

- **Tap**: Execute current mode action (send message, payment, or start recording)
- **Long Press (0.35s)**: Show mode selection menu
- **Drag-to-Select**: While holding, drag finger to menu items to highlight, release to select

Implementation uses:
- `DragGesture` with timer-based long press detection
- Named coordinate space (`chatCoordinateSpace`) for consistent positioning
- `connectionEpoch` pattern to track gesture ownership
- Haptic feedback at each interaction stage

## Documentation

| File | Description |
|------|-------------|
| `CLAUDE.md` | This file - project overview and guidance for Claude Code |
| `README.md` | Public project overview, feature list, and self-hosted cloud setup |
| `MESSAGING.md` | Kasia messaging protocol - encryption, handshakes, message types |
| `POOLS_v2.md` | gRPC node pool architecture - discovery, scoring, failover |
| `PUSH_NOTIFICATIONS.md` | Push notification architecture and rollout notes |
| `KAPOSTS_INDEXER.md` | Handoff/build guide for the KaChat-owned KaPosts indexer (protocol, API compatibility bar, required extensions) |
| `KAPOSTS_REPLIES_FIX.md` | The short server ask: the two read endpoints that make reply threads complete (`get-post`, optionally `get-thread`). Hand this over on its own; `KAPOSTS_INDEXER.md` is the reference behind it |
| `PUBLIC_CHATS_INDEXER.md` | Handoff/build guide for the KaChat Public Chats indexer (curated room history incl. `chess-arena`, REST spec, push, Docker; code/API keep their `broadcast` identifiers) |
| `TRANSLATION_SERVICE.md` | Handoff/build guide for the KaChat post translation endpoint (server-side translation of KaPosts, cached by txid; replaced the on-device Apple Translation / ML Kit path) |
| `PUSH_EXTENSIONS.md` | Server handoff: remote push for public chats + KaPosts (registration fields, APNs payload specs, routing contracts) |
| `ONLINE_CHESS.md` | Online Chess (5.1): public 1v1 and 8-player knockout tournaments in Kaspa Hub > Chess Online, every move a transaction in the `chess-arena` room, no referee (deterministic rules in `ChessTournamentEngine`), chain-time clocks with allowances; leaderboard handoff for the indexer |
| `KACHAT_APP_LINKS.md` | The kachat.app link site (`web_site/server/`): every shared link is `https://kachat.app/...` - Open Graph previews everywhere, Universal/App Links into the app, post-only page with download buttons without it |
| `DETERMINISTIC_ALIASES.md` | Deterministic alias derivation (shipped protocol - see `Utilities/DeterministicAlias.swift`): algorithm, migration notes, legacy-alias compatibility |

Historical plan/design documents were removed from the repo in the 4.0 hygiene pass; shipped code is the source of truth for those features.

## External References

The `external/` directory is gitignored except for `external/opus/`, which contains the vendored `Opus.xcframework` (a real linked build dependency for voice messages, not reference material). Reference repos (rusty-kaspa, kasia-indexer, kaspa-grpc, etc.) may be cloned locally under `external/` for protocol research, but they are not tracked in this repository.
