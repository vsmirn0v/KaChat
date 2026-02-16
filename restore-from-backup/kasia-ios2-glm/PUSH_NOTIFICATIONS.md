# Push Notifications Implementation Plan

## Overview

This document outlines the architecture for remote push notifications in Kasia iOS, enabling message delivery even when the app is backgrounded or closed.

## The Encryption Challenge

Kasia messages are end-to-end encrypted. The challenge is identifying the recipient without decryption:

| Message Type | TX Output To | Recipient Identifiable? |
|--------------|--------------|------------------------|
| **Payment** | Recipient address | Yes - from TX output |
| **Handshake** | Recipient address | Yes - from TX output |
| **Contextual Message** | Sender's address (self-stash) | No - encrypted inside payload |

**Solution**: Instead of identifying recipients, we flip the model:
- Devices register addresses they want to **watch** (their contacts)
- When a self-stash TX is detected FROM a watched address, push is sent
- App decrypts locally using stored keys

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         PUSH NOTIFICATION FLOW                        │
└──────────────────────────────────────────────────────────────────────┘

┌─────────────┐     ┌─────────────────────────────────────┐     ┌───────┐
│ Kaspa Node  │────▶│     kasia-indexer (forked)          │────▶│ APNs  │
│ (gRPC)      │     │                                     │     │       │
└─────────────┘     │ ┌─────────────────────────────────┐ │     └───┬───┘
                    │ │ NEW: PushNotificationActor      │ │         │
                    │ │ • Device registration DB        │ │         │
                    │ │ • Address subscription mapping  │ │         ▼
                    │ │ • APNs integration              │ │   ┌───────────┐
                    │ └─────────────────────────────────┘ │   │ iOS Device│
                    │                                     │   │ (Kasia)   │
                    │ Existing:                           │   └───────────┘
                    │ • BlockProcessor (message parsing)  │         ▲
                    │ • VirtualChainProcessor             │         │
                    │ • Database partitions               │    Device registers:
                    └─────────────────────────────────────┘    "Watch these addresses"
```

## Push with Encrypted Payload

Instead of generic "New message" notifications, we include the encrypted payload in the push. The app decrypts locally and displays the actual message content.

### Payload Size Strategy

APNs limit: 4KB max payload. Most text messages fit, but audio/files don't.

```
                    Encrypted payload size?
                           │
              ┌────────────┴────────────┐
              │                         │
         ≤ 3.5KB                    > 3.5KB
              │                         │
              ▼                         ▼
    ┌─────────────────┐      ┌─────────────────┐
    │ Include payload │      │ txId only       │
    │ in push         │      │ (no payload)    │
    └─────────────────┘      └─────────────────┘
              │                         │
              ▼                         ▼
    App decrypts locally      App fetches from API
    Shows actual message      Shows "New message"
                              Decrypts when opened
```

### Push Payload Examples

**Small message (≤3.5KB) - include payload:**
```json
{
  "aps": {
    "alert": { "title": "New Message", "body": "From kaspa:qz..." },
    "mutable-content": 1,
    "content-available": 1
  },
  "kasia": {
    "type": "contextual_message",
    "txId": "abc123...",
    "sender": "kaspa:qz...",
    "payload": "636970685f6d73673a313a...",
    "timestamp": 1704067200,
    "daaScore": 12345678
  }
}
```

**Large message (>3.5KB) - txId only:**
```json
{
  "aps": {
    "alert": { "title": "New Message", "body": "From kaspa:qz..." },
    "mutable-content": 1,
    "content-available": 1
  },
  "kasia": {
    "type": "contextual_message",
    "txId": "abc123...",
    "sender": "kaspa:qz...",
    "payload": null,
    "timestamp": 1704067200,
    "daaScore": 12345678
  }
}
```

### Message Type Handling

| Message Type | Typical Size | Push Strategy | User Sees |
|--------------|--------------|---------------|-----------|
| Text (short) | 200-500 bytes | Include payload | "Alice: Hey!" |
| Text (long) | 1-3KB | Include payload | "Alice: [full message]" |
| Voice message | 5-50KB+ | txId only | "Alice: Voice message" |
| Payment | ~500 bytes | Include payload | "Alice sent 10 KAS" |
| Handshake | ~200 bytes | Include payload | "Alice wants to connect" |

---

## Implementation Plan

### Phase 1: Fork kasia-indexer

Fork and extend the existing indexer with push notification capabilities.

**Why fork indexer (vs separate service):**
- Already parses Kasia messages in real-time
- Actor model makes adding PushNotificationActor clean
- Same database - no synchronization issues
- Single deployment

**New files to create:**
```
indexer/
├── src/
│   ├── push/
│   │   ├── mod.rs              # Push module
│   │   ├── actor.rs            # PushNotificationActor
│   │   ├── apns.rs             # APNs client (a]crate)
│   │   └── device_store.rs     # Device registration storage
│   └── routes/
│       └── push.rs             # REST endpoints for registration

indexer-db/
├── src/
│   └── partitions/
│       └── device_registration.rs  # New partition (15)
```

**New database partition:**
```rust
// PartitionId::DeviceRegistration = 15
struct DeviceRegistration {
    device_token: String,           // APNs device token
    platform: Platform,             // iOS (future: Android)
    watched_addresses: Vec<String>, // Addresses to monitor
    created_at: u64,
    last_seen: u64,
}

// Index: watched_address -> Vec<device_token>
// For fast lookup when message detected
```

**PushNotificationActor:**
```rust
const MAX_PAYLOAD_SIZE: usize = 3500;

impl PushNotificationActor {
    /// Called by BlockProcessor when contextual message indexed
    async fn on_contextual_message(
        &self,
        sender: &AddressPayload,
        tx_id: &str,
        payload: &str,
        timestamp: u64,
        daa_score: u64,
    ) {
        let devices = self.find_devices_watching(sender).await;

        let include_payload = payload.len() <= MAX_PAYLOAD_SIZE;

        for device in devices {
            let push = ApnsPush {
                alert: Alert {
                    title: "New Message".into(),
                    body: format!("From {}", sender.to_short_string()),
                },
                mutable_content: true,
                content_available: true,
                kasia: KasiaPayload {
                    msg_type: "contextual_message".into(),
                    tx_id: tx_id.into(),
                    sender: sender.to_string(),
                    payload: if include_payload { Some(payload.into()) } else { None },
                    timestamp,
                    daa_score,
                },
            };

            if let Err(e) = self.apns_client.send(&device.token, push).await {
                // Handle invalid tokens, remove stale registrations
                if e.is_invalid_token() {
                    self.remove_device(&device.token).await;
                }
            }
        }
    }

    /// Called when payment indexed
    async fn on_payment(
        &self,
        receiver: &AddressPayload,
        sender: &AddressPayload,
        amount: u64,
        memo: Option<&str>,
        tx_id: &str,
        timestamp: u64,
    ) {
        let devices = self.find_devices_for_address(receiver).await;

        for device in devices {
            let push = ApnsPush {
                alert: Alert {
                    title: "Payment Received".into(),
                    body: format!("{} KAS from {}", amount as f64 / 1e8, sender.to_short_string()),
                },
                mutable_content: true,
                kasia: KasiaPayload {
                    msg_type: "payment".into(),
                    tx_id: tx_id.into(),
                    sender: sender.to_string(),
                    amount: Some(amount),
                    memo: memo.map(|s| s.into()),
                    timestamp,
                    ..Default::default()
                },
            };

            self.apns_client.send(&device.token, push).await;
        }
    }

    /// Called when handshake indexed
    async fn on_handshake(
        &self,
        receiver: &AddressPayload,
        sender: &AddressPayload,
        tx_id: &str,
        timestamp: u64,
    ) {
        let devices = self.find_devices_for_address(receiver).await;

        for device in devices {
            let push = ApnsPush {
                alert: Alert {
                    title: "New Contact Request".into(),
                    body: format!("From {}", sender.to_short_string()),
                },
                mutable_content: true,
                kasia: KasiaPayload {
                    msg_type: "handshake".into(),
                    tx_id: tx_id.into(),
                    sender: sender.to_string(),
                    timestamp,
                    ..Default::default()
                },
            };

            self.apns_client.send(&device.token, push).await;
        }
    }
}
```

**New REST endpoints:**
```
POST /v1/push/register
{
    "device_token": "abc123...",
    "platform": "ios",
    "watched_addresses": ["kaspa:qz....", "kaspa:qp...."]
}
Response: 200 OK

PUT /v1/push/update
{
    "device_token": "abc123...",
    "watched_addresses": ["kaspa:qz....", "kaspa:qp....", "kaspa:qr...."]
}
Response: 200 OK

DELETE /v1/push/unregister
{
    "device_token": "abc123..."
}
Response: 200 OK

GET /v1/push/status?device_token=abc123...
Response: {
    "registered": true,
    "watched_addresses": ["kaspa:qz....", "kaspa:qp...."],
    "last_seen": 1704067200
}
```

---

### Phase 2: iOS App - Push Registration

**New file: `KaChat/Services/PushNotificationManager.swift`**

```swift
import UserNotifications
import UIKit

@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var isRegistered = false
    @Published private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

    private var deviceToken: String?
    private let indexerBaseURL: String

    init() {
        self.indexerBaseURL = AppSettings.load().indexerUrl
    }

    /// Request notification permission and register with APNs
    func requestPermissionAndRegister() async throws {
        let center = UNUserNotificationCenter.current()

        // Request permission
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw PushError.permissionDenied
        }

        // Register with APNs
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called from AppDelegate when APNs token received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = token

        Task {
            try? await registerWithIndexer()
        }
    }

    /// Register device with indexer, including watched addresses
    func registerWithIndexer() async throws {
        guard let token = deviceToken else {
            throw PushError.noDeviceToken
        }

        // Collect addresses to watch: own address + all contacts
        var watchedAddresses = Set<String>()

        if let wallet = WalletManager.shared.currentWallet {
            watchedAddresses.insert(wallet.publicAddress)
        }

        for contact in ContactsManager.shared.contacts {
            watchedAddresses.insert(contact.address)
        }

        let request = PushRegistrationRequest(
            deviceToken: token,
            platform: "ios",
            watchedAddresses: Array(watchedAddresses)
        )

        let url = URL(string: "\(indexerBaseURL)/v1/push/register")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (_, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PushError.registrationFailed
        }

        isRegistered = true
        NSLog("[Push] Registered with indexer, watching %d addresses", watchedAddresses.count)
    }

    /// Update watched addresses (call when contacts change)
    func updateWatchedAddresses() async throws {
        guard let token = deviceToken, isRegistered else { return }

        var watchedAddresses = Set<String>()

        if let wallet = WalletManager.shared.currentWallet {
            watchedAddresses.insert(wallet.publicAddress)
        }

        for contact in ContactsManager.shared.contacts {
            watchedAddresses.insert(contact.address)
        }

        let request = PushUpdateRequest(
            deviceToken: token,
            watchedAddresses: Array(watchedAddresses)
        )

        let url = URL(string: "\(indexerBaseURL)/v1/push/update")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (_, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PushError.updateFailed
        }

        NSLog("[Push] Updated watched addresses: %d", watchedAddresses.count)
    }

    /// Unregister device (call on logout/wallet delete)
    func unregister() async throws {
        guard let token = deviceToken else { return }

        let url = URL(string: "\(indexerBaseURL)/v1/push/unregister")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(["device_token": token])

        let (_, _) = try await URLSession.shared.data(for: urlRequest)

        isRegistered = false
        NSLog("[Push] Unregistered from indexer")
    }
}

// MARK: - Models

struct PushRegistrationRequest: Codable {
    let deviceToken: String
    let platform: String
    let watchedAddresses: [String]

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case platform
        case watchedAddresses = "watched_addresses"
    }
}

struct PushUpdateRequest: Codable {
    let deviceToken: String
    let watchedAddresses: [String]

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case watchedAddresses = "watched_addresses"
    }
}

enum PushError: LocalizedError {
    case permissionDenied
    case noDeviceToken
    case registrationFailed
    case updateFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Notification permission denied"
        case .noDeviceToken: return "No device token available"
        case .registrationFailed: return "Failed to register for push notifications"
        case .updateFailed: return "Failed to update push registration"
        }
    }
}
```

---

### Phase 3: iOS Notification Service Extension

Create a new target for processing push notifications before display.

**New target: `KaChatNotificationService`**

**`KaChatNotificationService/NotificationService.swift`:**

```swift
import UserNotifications
import CryptoKit

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent,
              let kasiaData = request.content.userInfo["kasia"] as? [String: Any],
              let sender = kasiaData["sender"] as? String,
              let txId = kasiaData["txId"] as? String,
              let msgType = kasiaData["type"] as? String
        else {
            contentHandler(request.content)
            return
        }

        // Load contact info from shared container
        let contact = SharedDataManager.getContact(address: sender)
        let contactName = contact?.alias ?? formatAddress(sender)

        switch msgType {
        case "contextual_message":
            handleContextualMessage(
                content: content,
                kasiaData: kasiaData,
                contact: contact,
                contactName: contactName,
                txId: txId,
                sender: sender
            )

        case "payment":
            handlePayment(
                content: content,
                kasiaData: kasiaData,
                contactName: contactName
            )

        case "handshake":
            content.title = "New Contact Request"
            content.body = "From \(contactName)"

        default:
            break
        }

        contentHandler(content)
    }

    private func handleContextualMessage(
        content: UNMutableNotificationContent,
        kasiaData: [String: Any],
        contact: SharedContact?,
        contactName: String,
        txId: String,
        sender: String
    ) {
        // Check if payload included (small message)
        if let payload = kasiaData["payload"] as? String,
           let contact = contact,
           let sharedSecret = contact.sharedSecret {

            // Try to decrypt
            if let decrypted = tryDecrypt(payload: payload, sharedSecret: sharedSecret) {
                content.title = contactName

                // Check message type
                if decrypted.hasPrefix("aud:") {
                    content.body = "Voice message"
                } else {
                    content.body = decrypted
                }

                // Store message in shared container for main app
                SharedDataManager.storeMessage(
                    txId: txId,
                    sender: sender,
                    content: decrypted,
                    timestamp: kasiaData["timestamp"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
                )
                return
            }
        }

        // Payload not included or decryption failed
        content.title = contactName
        content.body = "New message"

        // Mark as pending fetch
        SharedDataManager.addPendingMessage(txId: txId, sender: sender)
    }

    private func handlePayment(
        content: UNMutableNotificationContent,
        kasiaData: [String: Any],
        contactName: String
    ) {
        let amount = kasiaData["amount"] as? UInt64 ?? 0
        let kasAmount = Double(amount) / 100_000_000.0

        content.title = "Payment Received"

        if let memo = kasiaData["memo"] as? String, !memo.isEmpty {
            content.body = String(format: "%.8f KAS from %@: %@", kasAmount, contactName, memo)
        } else {
            content.body = String(format: "%.8f KAS from %@", kasAmount, contactName)
        }
    }

    private func tryDecrypt(payload: String, sharedSecret: Data) -> String? {
        // Parse payload: ciph_msg:1:msg:<alias>|<encrypted>
        guard payload.hasPrefix("ciph_msg:1:msg:"),
              let pipeIndex = payload.firstIndex(of: "|") else {
            return nil
        }

        let encryptedPart = String(payload[payload.index(after: pipeIndex)...])

        guard let encryptedData = Data(base64Encoded: encryptedPart) else {
            return nil
        }

        // Decrypt using KasiaCipher (shared code)
        do {
            let decrypted = try KasiaCipher.decrypt(data: encryptedData, sharedSecret: sharedSecret)
            return String(data: decrypted, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func formatAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))...\(address.suffix(6))"
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension is terminated
        if let contentHandler = contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }
}
```

**Shared Data Manager (App Group):**

```swift
// Shared between main app and extension via App Group
import Foundation

struct SharedContact: Codable {
    let address: String
    let alias: String
    let sharedSecret: Data?
}

struct SharedPendingMessage: Codable {
    let txId: String
    let sender: String
    let timestamp: Int64
}

class SharedDataManager {
    static let suiteName = "group.com.kachat.app"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // MARK: - Contacts

    static func getContact(address: String) -> SharedContact? {
        guard let data = defaults?.data(forKey: "contacts"),
              let contacts = try? JSONDecoder().decode([SharedContact].self, from: data) else {
            return nil
        }
        return contacts.first { $0.address == address }
    }

    static func syncContacts(_ contacts: [SharedContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        defaults?.set(data, forKey: "contacts")
    }

    // MARK: - Pending Messages

    static func addPendingMessage(txId: String, sender: String) {
        var pending = getPendingMessages()
        pending.append(SharedPendingMessage(
            txId: txId,
            sender: sender,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        ))

        if let data = try? JSONEncoder().encode(pending) {
            defaults?.set(data, forKey: "pendingMessages")
        }
    }

    static func getPendingMessages() -> [SharedPendingMessage] {
        guard let data = defaults?.data(forKey: "pendingMessages"),
              let pending = try? JSONDecoder().decode([SharedPendingMessage].self, from: data) else {
            return []
        }
        return pending
    }

    static func clearPendingMessages() {
        defaults?.removeObject(forKey: "pendingMessages")
    }

    // MARK: - Decrypted Messages (from extension)

    static func storeMessage(txId: String, sender: String, content: String, timestamp: Int64) {
        var messages = getStoredMessages()
        messages.append([
            "txId": txId,
            "sender": sender,
            "content": content,
            "timestamp": timestamp
        ] as [String: Any])

        if let data = try? JSONSerialization.data(withJSONObject: messages) {
            defaults?.set(data, forKey: "storedMessages")
        }
    }

    static func getStoredMessages() -> [[String: Any]] {
        guard let data = defaults?.data(forKey: "storedMessages"),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return messages
    }

    static func clearStoredMessages() {
        defaults?.removeObject(forKey: "storedMessages")
    }
}
```

---

### Phase 4: Xcode Project Configuration

**1. Add Notification Service Extension target:**
- File > New > Target > Notification Service Extension
- Name: `KaChatNotificationService`
- Bundle ID: `com.kachat.app.NotificationService`

**2. Configure App Groups:**

Main App (`Kasia.entitlements`):
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.kachat.app</string>
</array>
```

Extension (`KaChatNotificationService.entitlements`):
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.kachat.app</string>
</array>
```

**3. Configure Keychain Sharing** (for shared secret access):

Main App:
```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.kachat.app</string>
</array>
```

Extension:
```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.kachat.app.KaChatNotificationService</string>
</array>
```

**4. Enable Push Notifications capability** in main app

**5. Enable Background Modes:**
- Remote notifications

---

## Privacy Considerations

| Data | Exposed to Indexer | Notes |
|------|-------------------|-------|
| Device token | Yes | Required for APNs |
| Watched addresses | Yes | Your contacts' addresses |
| Message content | No | Encrypted, decrypted only on device |
| Social graph | Partially | Indexer knows who you watch |

This is acceptable since the indexer already indexes all on-chain messages. Adding device registration doesn't reveal new information beyond the social graph (which addresses you're interested in).

---

## Testing Checklist

- [ ] Push permission request flow
- [ ] Device registration with indexer
- [ ] Contact add/remove updates watched addresses
- [ ] Small message: payload included, decrypted, displayed
- [ ] Large message (audio): txId only, generic display, fetched on open
- [ ] Payment notification with amount
- [ ] Handshake notification
- [ ] App backgrounded: push received and processed
- [ ] App killed: push received, extension processes
- [ ] Invalid token cleanup
- [ ] Wallet logout: unregister from indexer

---

## Future Enhancements

1. **Android support**: Add FCM integration to indexer
2. **Rich notifications**: Include contact avatar
3. **Notification grouping**: Group messages by contact
4. **Quick reply**: Reply from notification (iOS supports this)
5. **End-to-end verification**: Sign push payloads to prevent tampering
