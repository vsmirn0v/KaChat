# KaChat (iOS)

KaChat is a native SwiftUI iOS app for encrypted peer-to-peer messaging and payments on the Kaspa blockchain.

It combines:
- End-to-end encrypted messaging (`ciph_msg:1:*` payloads on-chain)
- Native KAS payments with optional encrypted memos
- Voice message support (Opus)
- KNS (Kaspa Name Service) domain resolution
- Real-time UTXO-based updates with resilient node failover
- CloudKit-backed multi-device message sync
- Push notifications with optional encrypted payload delivery

## Project Status

This repository contains an actively developed app and companion extensions:
- Main app target: `KaChat`
- Notification Service Extension: `KaChatNotificationService`
- Share Extension: `KaChatShareExtension`

Current deployment target is iOS 16.0.

## Key Features

- Wallet onboarding/import and secure key handling
- One-to-one encrypted chats using handshake + contextual message flow
- On-chain KAS transfers integrated into conversations
- Voice message sending/receiving
- Contact management with aliases and KNS names
- Configurable network endpoints (Kaspa REST API, Indexer, KNS API)
- Adaptive real-time sync via gRPC UTXO subscriptions and fallback polling
- Background/terminated delivery via remote push mode
- Per-wallet CloudKit zones for message isolation
- Localization support across multiple languages (`*.lproj`)

## Architecture

KaChat follows MVVM with singleton services injected through `@EnvironmentObject`.

- Entry point: `KaChat/App/KaChatApp.swift`
- Views: SwiftUI screens under `KaChat/Views/*`
- View models: `KaChat/ViewModels/*`
- Core services: `KaChat/Services/*`
- Node pool subsystem: `KaChat/Services/NodePool/*`
- Models: `KaChat/Models/Models.swift`

Core service responsibilities:
- `WalletManager`: wallet lifecycle, key derivation, balance
- `ChatService`: conversation state, sync, send/receive logic
- `NodePoolService`: gRPC node pool orchestration
- `UtxoSubscriptionManager`: subscription lifecycle + failover
- `KasiaAPIClient`: indexer HTTP client
- `KNSService`: domain lookup and caching
- `MessageStore`: Core Data + CloudKit persistence
- `PushNotificationManager`: APNs registration and reliability logic

## Messaging and Payment Model

KaChat uses Kasia protocol payloads embedded in Kaspa transactions:

- Handshake: `ciph_msg:1:hs:*`
- Contextual message: `ciph_msg:1:msg:*`
- Payment memo: `ciph_msg:1:pay:*`

Contextual messages use a self-stash pattern:
- Sender spends own UTXOs
- Output returns to sender address
- Encrypted payload is attached
- Recipient watches sender address activity to detect new messages

Payments and handshakes are recipient-addressed transactions and require sender resolution from transaction inputs.

See [MESSAGING.md](MESSAGING.md) for full protocol details.

## Networking and Sync

KaChat combines multiple channels:
- Kaspa gRPC nodes for UTXO subscriptions and transaction operations
- Kaspa REST API for transaction resolution and fallback flows
- Kasia Indexer REST API for message indexing and retrieval
- KNS API for domain resolution

Node connectivity is managed by the POOLS_v2 architecture:
- seed + peer discovery
- capability-aware selection
- health scoring and circuit breakers
- sticky subscription with warm standby failover
- dynamic aggressive/conservative probing modes

See [POOLS_v2.md](POOLS_v2.md) for details.

## Security and Storage

- Keys/seeds are wrapped with device-specific Secure Enclave keys
- Message persistence uses Core Data with CloudKit sync
- Data is partitioned per wallet (wallet-specific store/zone)
- App Group sharing supports extension interoperability

Bundle identifiers used by the app:
- App: `com.kachat.app`
- CloudKit container: `iCloud.com.kachat.app`
- App Group: `group.com.kachat.app`

## Push Notifications

Push supports background/terminated message delivery using a push-capable Kasia indexer.

- Devices register watched addresses
- Small encrypted payloads can be included directly in APNs payload
- Large payloads fall back to tx-id based fetch/decrypt
- Runtime reliability scoring gates catch-up sync behavior

See [PUSH_NOTIFICATIONS.md](PUSH_NOTIFICATIONS.md) and [PUSH_SECURITY_AUDIT.md](PUSH_SECURITY_AUDIT.md).

## Repository Structure

```text
.
├── KaChat/                       # Main iOS app target
│   ├── App/                      # App entry/router/tab shell
│   ├── Models/                   # Data models
│   ├── Services/                 # Business logic, networking, crypto helpers
│   ├── Services/NodePool/        # gRPC node pool subsystem
│   ├── ViewModels/               # SwiftUI view models
│   ├── Views/                    # Feature views (Chat, Contacts, Settings, etc.)
│   └── Utilities/                # Supporting utilities
├── KaChatNotificationService/    # Notification Service Extension
├── KaChatShareExtension/         # Share Extension
├── Frameworks/                   # Vendored XCFramework dependencies
├── external/                     # Reference repos and protocol implementations
└── *.md                          # Architecture/protocol/security docs
```

## Dependencies

- `P256K.xcframework` for secp256k1 operations/signing
- `GRPCAll.xcframework` and `SwiftProtobuf.xcframework` for gRPC stack
- `YbridOpus` Swift package (from `opus-swift`) for voice codec integration

## Getting Started

1. Open `KaChat.xcodeproj` in Xcode.
2. Configure signing/capabilities for your Apple team.
3. Ensure required capabilities are enabled for targets:
   - Push Notifications
   - Background Modes (remote notifications/fetch as used)
   - App Groups (`group.com.kachat.app`)
   - iCloud/CloudKit (`iCloud.com.kachat.app`)
4. Select a simulator/device (iOS 16+).
5. Build and run.

## Build and Test Commands

```bash
# Open in Xcode
open KaChat.xcodeproj

# Build
xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests
xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'platform=iOS Simulator,name=iPhone 17' test

# Clean
xcodebuild -project KaChat.xcodeproj -scheme KaChat clean
```

## Configuration

Connection settings are user-configurable in-app:
- Network: mainnet/testnet
- Kasia Indexer URL
- KNS API URL
- Kaspa REST API URL

Defaults are managed via `AppSettings`.

## Documentation Map

- [CLAUDE.md](CLAUDE.md): architecture and development guidance
- [MESSAGING.md](MESSAGING.md): protocol and transaction semantics
- [POOLS_v2.md](POOLS_v2.md): node pool and failover architecture
- [PUSH_NOTIFICATIONS.md](PUSH_NOTIFICATIONS.md): push delivery design
- [PUSH_SECURITY_AUDIT.md](PUSH_SECURITY_AUDIT.md): push threat model/mitigations

## Known Limitations

- Per-contact realtime disable path is currently documented as unstable/broken and needs follow-up fixes.
- TODO: Integrate VCC2 API in a future update; this is strongly desired to provide a more stable messaging pipeline.

## Support

Support KaChat development via KAS donation:

`kachat-donate.kas`  
`kaspa:qp4jkz5jmajtdgtf4k8r5hrgwzal3ge7j3z92zv62qux5dhvgcrsxwhh5r7z4`
