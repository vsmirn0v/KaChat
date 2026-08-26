# KaChat (iOS)
<details>
<summary>Summary</summary>

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

<details>
<summary>Summary</summary>

This repository contains an actively developed app and companion extensions:
- Main app target: `KaChat`
- Notification Service Extension: `KaChatNotificationService`
- Share Extension: `KaChatShareExtension`
- Widgets Extension: `KaChatWidgetsExtension`

Current deployment target is iOS 16.0 (widgets require iOS 17.0). The current release train is 4.0.

</details>

## Key Features

<details>
<summary>Summary</summary>

- Wallet onboarding/import and secure key handling (Secure Enclave wrapped)
- One-to-one encrypted chats using handshake + contextual message flow
- Encrypted group chats (`kchat:1:gcomm` / `gctl` payloads)
- Public broadcast channels (for example `#kaspa`) with hideable senders
- KaPosts: on-chain social posts tied to KNS identities
- On-chain KAS transfers integrated into conversations, with reactions, image attachments, link previews, and in-chat chess games
- Fresh-address payment pools for payment privacy (see MESSAGING.md)
- Voice message sending/receiving (Opus)
- Contact management with aliases, KNS names, and KNS profile creation
- Portfolio tracking across multiple coins (CoinGecko pricing) and address import
- In-app swap via ChangeNow
- Cold storage accounts with air-gapped signing (KSPT QR flow, KasSigner companion)
- Gift claim onboarding flow
- Child Mode (parent-set password gate for sensitive actions)
- Chat history backup: CloudKit sync plus encrypted Nextcloud backup/auto-sync
- Home screen widgets, share extension, and App Shortcuts
- Configurable network endpoints (Kaspa REST API, Indexer, KNS API)
- Adaptive real-time sync via gRPC UTXO subscriptions and fallback polling
- Background/terminated delivery via remote push mode
- Per-wallet CloudKit zones for message isolation
- Localization support across 19 languages (`*.lproj`)

</details>

## Architecture

<details>
<summary>Summary</summary>

KaChat follows MVVM with singleton services injected through `@EnvironmentObject`.

- Entry point: `KaChat/App/KaChatApp.swift`
- Views: SwiftUI screens under `KaChat/Views/*`
- View models: `KaChat/ViewModels/*`
- Core services: `KaChat/Services/*`
- Node pool subsystem: `KaChat/Services/NodePool/*`
- Models: `KaChat/Models/*` (`Models.swift`, `PortfolioModels.swift`, `SwapModels.swift`)

Core service responsibilities:
- `WalletManager`: wallet lifecycle, key derivation, balance
- `ChatService`: conversation state, sync, send/receive logic
- `NodePoolService`: gRPC node pool orchestration
- `UtxoSubscriptionManager`: subscription lifecycle + failover
- `KasiaAPIClient`: indexer HTTP client
- `KNSService`: domain lookup and caching
- `MessageStore`: Core Data + CloudKit persistence
- `PushNotificationManager`: APNs registration and reliability logic

</details>

## Messaging and Payment Model

<details>
<summary>Summary</summary>

KaChat uses Kasia protocol payloads embedded in Kaspa transactions (written with the `kchat:1:` root; the legacy `ciph_msg:1:` root is still accepted on read):

- Handshake: `kchat:1:handshake:*`
- Contextual message: `kchat:1:comm:*`
- Payment memo: `kchat:1:pay:*`
- Broadcast post: `kchat:1:bcast:*`
- Group message/control: `kchat:1:gcomm:*` / `kchat:1:gctl:*`

Contextual messages use a self-stash pattern:
- Sender spends own UTXOs
- Output returns to sender address
- Encrypted payload is attached
- Recipient watches sender address activity to detect new messages

Payments and handshakes are recipient-addressed transactions and require sender resolution from transaction inputs.

See [MESSAGING.md](MESSAGING.md) for full protocol details.

</details>

## Networking and Sync

<details>
<summary>Summary</summary>

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

</details>

## Security and Storage

<details>
<summary>Summary</summary>

- Keys/seeds are wrapped with device-specific Secure Enclave keys
- Message persistence uses Core Data with CloudKit sync
- Data is partitioned per wallet (wallet-specific store/zone)
- App Group sharing supports extension interoperability

Bundle identifiers used by the app:
- App: `com.kachat.app`
- CloudKit container: `iCloud.com.kachat.app`
- App Group: `group.com.kachat.app`

</details>

### Security Notes

The at-rest model, plainly:

- Message history lives in the app sandbox, protected by iOS file-based encryption (Data Protection). Message content is additionally encrypted at rest with a key derived from the wallet, so the local database never holds plaintext messages and any device backup of it carries only ciphertext.
- Cloud copies are end-to-end encrypted with the wallet key: CloudKit syncs only the wallet-encrypted content, and Nextcloud backup archives are sealed in the encrypted backup envelope (see MESSAGING.md) before upload. Without the wallet, cloud copies are ciphertext.
- Seed phrases and private keys are wrapped by this device's Secure Enclave and stored in the Keychain. They never leave the device and are not included in any backup.

## Push Notifications

<details>
<summary>Summary</summary>

Push supports background/terminated message delivery using a push-capable Kasia indexer.

- Devices register watched addresses
- Small encrypted payloads can be included directly in APNs payload
- Large payloads fall back to tx-id based fetch/decrypt
- Runtime reliability scoring gates catch-up sync behavior

See [PUSH_NOTIFICATIONS.md](PUSH_NOTIFICATIONS.md) and [PUSH_EXTENSIONS.md](PUSH_EXTENSIONS.md).

</details>

## Repository Structure

<details>
<summary>Summary</summary>

```text
.
├── KaChat/                       # Main iOS app target
│   ├── App/                      # App entry/router/tab shell
│   ├── Models/                   # Data models
│   ├── Services/                 # Business logic, networking, crypto helpers
│   ├── Services/NodePool/        # gRPC node pool subsystem
│   ├── Shortcuts/                # App Intents / Shortcuts integration
│   ├── Generated/                # Generated protobuf/gRPC sources
│   ├── ViewModels/               # SwiftUI view models
│   ├── Views/                    # Feature views (Chat, Contacts, Settings, etc.)
│   └── Utilities/                # Supporting utilities
├── KaChatNotificationService/    # Notification Service Extension
├── KaChatShareExtension/         # Share Extension
├── KaChatWidgets/                # Widgets Extension
├── external/opus/                # Vendored Opus.xcframework (voice codec)
├── ci_scripts/                   # Xcode Cloud hooks
├── scripts/                      # Build helpers and script-based tests
├── web_site/                     # Static marketing/EULA pages
└── *.md                          # Architecture/protocol docs
```

</details>

## Dependencies

<details>
<summary>Summary</summary>

Swift Package Manager (resolved via `Package.resolved`, no manual install needed):
- `swift-secp256k1` (product `P256K`) for secp256k1 operations/signing
- `grpc-swift` and `swift-protobuf` for the gRPC stack

Vendored:
- `external/opus/Opus.xcframework` for the voice codec, linked through the `OpusBridge` Objective-C bridge

</details>

## Getting Started

<details>
<summary>Summary</summary>

1. Open `KaChat.xcodeproj` in Xcode.
2. Configure signing/capabilities for your Apple team.
3. Ensure required capabilities are enabled for targets:
   - Push Notifications
   - Background Modes (remote notifications/fetch as used)
   - App Groups (`group.com.kachat.app`)
   - iCloud/CloudKit (`iCloud.com.kachat.app`)
4. Select a simulator/device (iOS 16+).
5. Build and run.

</details>

## Build and Test Commands

<details>
<summary>Summary</summary>

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

</details>

## Configuration

<details>
<summary>Summary</summary>

Connection settings are user-configurable in-app:
- Network: mainnet/testnet
- Kasia Indexer URL
- KNS API URL
- Kaspa REST API URL

Defaults are managed via `AppSettings`.

</details>

## Documentation Map

<details>
<summary>Summary</summary>

- [CLAUDE.md](CLAUDE.md): architecture and development guidance
- [MESSAGING.md](MESSAGING.md): protocol and transaction semantics
- [POOLS_v2.md](POOLS_v2.md): node pool and failover architecture
- [PUSH_NOTIFICATIONS.md](PUSH_NOTIFICATIONS.md): push delivery design
- [PUSH_EXTENSIONS.md](PUSH_EXTENSIONS.md): push server handoff for broadcasts and KaPosts
- [BROADCAST_INDEXER.md](BROADCAST_INDEXER.md) and [KAPOSTS_INDEXER.md](KAPOSTS_INDEXER.md): indexer build guides

</details>

## Self-Hosted Cloud (Nextcloud) Setup

KaChat can preview and stream **Nextcloud public share links** (photos and videos) directly
inside a chat, and can use Nextcloud as a private destination for chat-history backup. Hosting
your own Nextcloud gives you a personal media/backup server that you fully control.

The complete one-command setup — Nextcloud + Portainer + Nginx Proxy Manager, with photo/video
previews (including iPhone HEIC and video thumbnails) pre-configured — now lives in its own repo:

**➡️ [KaChat-NextCloud](https://github.com/KaspaSilver/KaChat-NextCloud)**

Quick start:

**macOS & Linux** — open a terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/KaspaSilver/KaChat-NextCloud/main/scripts/kachat-cloud-setup.sh | bash
```

**Windows** — open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/KaspaSilver/KaChat-NextCloud/main/scripts/kachat-cloud-setup.ps1 | iex
```

See the [KaChat-NextCloud README](https://github.com/KaspaSilver/KaChat-NextCloud#readme) for
logging in, running on your local network, exposing it publicly over HTTPS with a free DuckDNS
domain, verifying previews, and everyday commands.

## Support

Support KaChat development via KAS donation:

`kachat-donate.kas`  
`kaspa:qp4jkz5jmajtdgtf4k8r5hrgwzal3ge7j3z92zv62qux5dhvgcrsxwhh5r7z4`
