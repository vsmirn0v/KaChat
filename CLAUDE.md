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
| `MessageStore` | Core Data + CloudKit message persistence with per-wallet zones |
| `ContactsManager` | Address book persistence, KNS domain integration |
| `KNSService` | Kaspa Name Service API client for domain resolution |
| `KasiaTransactionBuilder` | Constructs signed Kaspa transactions |

### Messaging Protocol

1. **Handshake**: Initial key exchange, stored in sender's self-stash on-chain
2. **Contextual Messages**: Encrypted messages using shared secret derived from handshake
3. **Payments**: On-chain KAS transfers with optional encrypted metadata
4. **Audio**: Voice messages encoded with YbridOpus codec

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

### Per-Contact Realtime Updates

> **⚠️ TODO:** This feature is currently broken and not working as expected. Needs investigation and fix in a future update.

Contacts can have realtime UTXO subscriptions disabled individually:

**Toggle in Chat Info:**
- `Contact.realtimeUpdatesDisabled` flag (default: false)
- When disabled, contact is excluded from UTXO subscription addresses
- Messages/payments fetched via periodic polling (60s interval) instead

**Spam Detection:**
- Tracks irrelevant TX notifications per contact (sliding 1-minute window)
- Threshold: 20+ irrelevant TXs in 1 minute triggers warning
- `NoisyContactWarning` struct with contactAddress, alias, txCount
- Warning popup in `MainTabView` with "Disable" and "Dismiss" options
- Dismissed warnings are tracked per-session (resets on app restart)
- "Disable" immediately disables realtime for that contact

**Key Components:**
- `ChatService.contactTxNotifications: [String: [Date]]` - tracks notification timestamps
- `ChatService.dismissedSpamWarnings: Set<String>` - session-dismissed warnings
- `ChatService.noisyContactWarning: NoisyContactWarning?` - published for UI binding
- `ChatService.recordIrrelevantTxNotification(contactAddress:)` - records and checks threshold

### gRPC Node Pool (POOLS_v2)

The app uses a sophisticated gRPC-based node pool architecture (see `POOLS_v2.md` for full design):

**Node Discovery (`NodeProfiler`):**
- Resolves DNS seeds using `getaddrinfo()` for all A records
- Discovers peers via `getPeerAddresses` from active nodes
- Filters by allowed gRPC ports (16110/16210 for mainnet/testnet)

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
- **Core Data + CloudKit**: Messages synced via `NSPersistentCloudKitContainer` with per-wallet zones
- **UserDefaults**: Settings, contact aliases (fallback for wallet)

### Multi-Device & CloudKit Architecture

The app supports multiple devices with the same iCloud account, potentially using different wallets.

**Bundle Identifiers:**
- Bundle ID: `com.kachat.app`
- CloudKit Container: `iCloud.com.kachat.app`
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
"kasia_seed_phrase_a1b2c3d4e5f6g7h8"  // Device 1
"kasia_seed_phrase_9i8j7k6l5m4n3o2p"  // Device 2
```

- Each device must enter the seed phrase separately during setup
- SE-wrapped data cannot be decrypted on other devices
- `hasSeedPhrase()` and `hasPrivateKey()` check for device-specific keys

**Per-Wallet CloudKit Zones (`MessageStore`):**

Messages are partitioned by wallet address using separate CKRecordZones and SQLite files:

```swift
// Zone name derived from wallet address hash
let zoneId = "wallet-\(SHA256(walletAddress).prefix(8).hexString)"

// SQLite file per wallet
"KasiaMessages-a1b2c3d4.sqlite"  // Wallet 1
"KasiaMessages-e5f6g7h8.sqlite"  // Wallet 2
```

- User can use different wallets on different devices with same iCloud account
- Switching wallets reloads the appropriate message store
- `purgeCurrentWalletCloudKitData()` only affects current wallet's zone
- All Core Data queries filter by `walletAddress` field

## Code Organization

```
KaChat/
├── App/              # KaChatApp, ContentView (router), MainTabView
├── Models/           # Models.swift - all data structures in one file
├── ViewModels/       # SettingsViewModel
├── Views/            # SwiftUI views by feature: Chat/, Contacts/, Onboarding/, Settings/
├── Services/         # Core business logic, API clients, crypto utilities
└── Utilities/        # CryptoUtils, KasiaCipher (ECIES), Bech32
```

## Key Dependencies

- **P256K**: secp256k1 elliptic curve library for key derivation and signing
- **YbridOpus**: Audio codec for voice messages (Objective-C bridge via `OpusBridge.h/m`)

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
| `docs/README.md` | Canonical documentation index + archive map |
| `MESSAGING.md` | Kasia messaging protocol - encryption, handshakes, message types |
| `POOLS_v2.md` | gRPC node pool architecture - discovery, scoring, failover |
| `PUSH_NOTIFICATIONS.md` | Push notification architecture and rollout notes |
| `PUSH_SECURITY_AUDIT.md` | Push service security review and mitigation plan |
| `docs/archive/2026-02/POOLS.md` | Legacy pool design (v1), archived |
| `docs/archive/2026-02/POOLS_v2_IMPROVEMENTS.md` | Historical POOLS_v2 implementation plan, archived |

## External References

The `external/` directory contains reference implementations (not part of the iOS build):

| Directory | Description |
|-----------|-------------|
| `KaChat/` | Web/Tauri version of Kasia - reference for messaging protocol, encryption, and UI patterns |
| `rusty-kaspa/` | Official Kaspa blockchain Rust implementation - reference for wRPC protocol, Borsh encoding, transaction formats |
| `kasia-indexer/` | Kasia message indexing service - reference for indexer API endpoints and message storage format |
| `kaspa-grpc/` | Kaspa gRPC protocol definitions - reference for RPC message structures and opcodes |
| `kaspium_wallet/` | Kaspium Flutter wallet - reference for transaction building and UTXO management |
| `workflow-rs/` | Aspectron's Rust workflow library - reference for wRPC resolver protocol and endpoint discovery |

These repos are useful for understanding protocol details, message formats, and implementation patterns when building iOS equivalents.
