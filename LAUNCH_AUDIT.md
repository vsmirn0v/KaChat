# KaChat 5.1 — App Store launch audit

Date: 2026-09-25. Scope: the iOS app and its four extensions at commit 727d191, read-only.
Five passes: security, App Store review compliance, performance and stability, release hygiene,
and every data flow that leaves the device (for the privacy label and policy). Every finding was
verified in source; the ones marked ✔ were re-checked by hand after the passes.

Verdict: **not ready to submit yet.** One review blocker, four likely rejections, two crash-class
bugs and one high-severity security gap stand between this build and the store. None is large;
the list below is ordered so the first section is the minimum to submit.

---

## 1. Must fix before submitting

| # | Finding | Where | Fix |
|---|---|---|---|
| 1 | ✔ **No privacy policy or terms** in the app or on kachat.app (`/privacy`, `/terms` → 404). Apple needs the policy URL in App Store Connect *and* reachable in the app; with user-generated content (KaPosts, Public Chats, groups) reviewers also expect terms with a zero-tolerance clause the user accepts. | `ContactsView.swift:1526-1531` (About has only linktr.ee + Gmail) | Publish both pages from `web_site/server/`, add rows in About and Settings, gate first entry into KaPosts and Public Chats on a one-time terms acceptance. |
| 2 | ✔ **Amount fields crash the app.** Every KAS→sompi conversion is `UInt64((kas * 1e8).rounded())` guarded only by `kas >= 0`. `1e300`, `inf`, or any 12-plus-digit number passes the guard and traps in release. | `ChatDetailView.swift:3662`, `ContactsView.swift:4538, 4979`, `PublicChatChannelView.swift:927`, `GroupChatDetailView.swift:1069`, `ColdStorageView.swift:1224, 1637`, `ManageAddressesView.swift:1401, 1541, 1980`, `KaPostsView.swift:6082, 6351`, `KaPostsSettingsView.swift:80`, `SwapView.swift:114` | One shared helper: `kas.isFinite && kas >= 0 && kas <= 28_700_000_000` before converting (or the `Decimal` path in `KNSService.swift:1796`). |
| 3 | ✔ **Core Data stores open synchronously on the main thread at launch.** Any migration or WAL recovery after a jetsam runs on main; the 12 s timeout cannot fire because the load blocks the thread it needs; a failed load only logs and the app runs with no persistence. Watchdog (0x8badf00d) risk on large stores. | `MessageStore.swift:1745` (`shouldAddStoreAsynchronously = false`), `:147, :184, :218, :1765, :1783`; `PublicChatStore.swift:107-112`; `GroupStore.swift` | Set the flag true (completion plumbing exists), run the index builder inside the completion, add a destroy-and-recreate fallback for the incompatible-store error on the cache-like stores. |
| 4 | ✔ **Message sender is trusted from the push and indexer servers.** `addMessageFromPush` takes `sender` from the APNs payload and files the message under that contact; the fetch path files by the alias polled. The ECIES envelope carries no sender signature, so the server (or anyone who takes over the DuckDNS host) can plant "send 500 KAS to X" messages that render as a trusted contact. | `ChatService+PushAndSync.swift:891-921`, `NotificationService.swift:116`, `ChatService+Fetching.swift:1800-1845`, `KaChatCipher.swift:69-144` | Before showing a message as from a contact, confirm the txId exists on chain with an input from `sender` (REST tx lookup) and mark the rest "unverified". Longer term add a sender Schnorr signature inside the encrypted payload (protocol change with desktop and Android). |
| 5 | ✔ **Export compliance is mis-declared.** `ITSAppUsesNonExemptEncryption = false` while the app implements ECIES, ChaCha20-Poly1305, AES-GCM and secp256k1. | `Resources/Info.plist:20-21` | Either set it true, answer "standard algorithms, mass-market 5D992.c" and file the annual self-classification report, or keep false only after sending the EAR 742.15(b) public-source notification (repo is public) and documenting it. |
| 6 | **Public Chats and groups have Hide but no Report; 1:1 has no Block.** Guideline 1.2 requires a report path and blocking for UGC. KaPosts already has Report, Mute, Block. | `PublicChatChannelView.swift:1371`, `GroupChatDetailView.swift:1474`, `ChatDetailView.swift:2412-2424` | Reuse the KaPosts `reportPost` mailto row in the public-chat and group message sheets; add Block for an address in 1:1 (suppress handshakes and messages). |
| 7 | **Privacy label is empty but data is collected.** All five manifests declare no collected data. The push server receives device token, wallet address and all watched contact addresses; ipapi.co derives coarse location from the IP; the translation endpoint receives post text. | `PushNotificationManager.swift:88-92, 2203-2290`, `NodeProfiler.swift:891-945`, `PostTranslationService.swift:389-399` | Declare in the manifest and App Store Connect: Identifiers (wallet address, device token, linked), Contacts (contact address list leaves the device), User Content (posts to translation), Coarse Location (IP-derived, not linked). Or drop the ipapi.co hop and use the bundled `geoip-lite.json`. |
| 8 | ✔ **Whole backend defaults to a DuckDNS hostname.** Indexer, push, KaPosts and translation default to `https://kachat.duckdns.org`; it is also an associated domain in both entitlements and serves no AASA (404). That host receives push tokens, DeviceCheck tokens, every watched address and aliases. If the subdomain lapses, its next owner inherits all of it plus finding 4. | `Models.swift:2173-2192`, `KaChat.entitlements:10`, `KaChatRelease.entitlements:10`, `SettingsView.swift:1925` | Move defaults to a `kachat.app` subdomain, add the old host to the `supersededIndexerDefaults` sweep at `Models.swift:2568` so installs migrate, drop the duckdns applinks entry. |
| 9 | **"Child Mode" naming on a 17-plus crypto wallet.** A mode named for children on an app with self-custody payments, Swap and an unrestricted web view invites a Kids/COPPA question and a metadata mismatch. | `ChildModeSettingsView.swift:53-372`, `WelcomeGuideView.swift:349` | Rename to "Restricted Mode" and describe it as hiding social and swap features behind a password; declare crypto and unrestricted web access in the age rating. |
| 10 | **Flip the release flag and version.** `KACHAT_IS_RELEASE = NO`, so About shows "5.1 (1)". | `Version.xcconfig:64-67` | Set YES for the store archive. Xcode Cloud will assign the build number. |

## 2. Should fix before or right after launch

### Security and privacy
- **gRPC to Kaspa nodes is plaintext by default** and carries own plus every contact's address in one subscription. Node operators and on-path observers learn the social graph. ✔ `NodeModels.swift:19`, `GRPCStreamConnection.swift:340`, `ChatService+PushAndSync.swift:613-632`. Prefer TLS-capable nodes when known, offer a pinned "my node", or subscribe contacts only via the TLS indexer.
- **Decrypted message text parked in App Group UserDefaults** by the notification extension until the app next runs; the plist has default protection and is backed up. `NotificationService.swift:1208-1233`, `SharedDataManager.swift:461-495`. Hand over txId plus ciphertext, or write a file with complete protection and backup exclusion.
- **Local stores have no file protection or backup exclusion.** Core Data SQLite files (decrypted message bodies with photos and voice notes inline as base64), contacts JSON, KaPosts drafts, node registry and the App Group defaults are all included in iCloud and local backups. Only the avatar cache is excluded. `MessageStore.swift:118-127, 342, 945`, `GroupStore.swift:26`, `PublicChatStore.swift:72`, `ContactsManager.swift:38-40, 2014-2021`. Set `NSPersistentStoreFileProtectionKey` to complete-unless-open and exclude derived data from backup. Keychain is correct throughout: device-only, non-synchronizable, seed and private key Secure Enclave wrapped.
- **Push registration over-shares**: hidden-sender lists, KaPosts preference toggles, room memberships and aliases, all bound to the signed wallet key. `PushNotificationManager.swift:2203-2290`. Filter hidden senders and rooms on the device instead.
- **Nextcloud media uploads are unencrypted behind public share links**; legacy plaintext archives are still read. `NextcloudService.swift:1445-1486, 1794-1800`. Disclose in the policy; consider encrypting media like the archive.
- **Third-party IP geolocation** (ipify, ifconfig.me, ipapi.co) on pool startup with no toggle; coordinates persisted in UserDefaults. `NodeProfiler.swift:892-924`. Drop it or disclose it.
- **KaPosts sends the requester pubkey on every read**, so the indexer can log reading behaviour per identity. `KaPostsAPIClient.swift:292-294`.
- **Link previews auto-fetch third-party URLs for accepted contacts** with spoofed user agents and no private-range filter; contact-set avatar URLs are fetched automatically, so a contact can beacon your IP. `LinkPreviewService.swift:376-380, 477-481, 738-790`, `KNSAvatarView.swift:767`. Add a setting and block RFC1918/loopback hosts.
- **Silent fallback to unwrapped keychain storage** when Secure Enclave wrapping throws, with no signal to the user. `KeychainService.swift:419-424, 455-460`. Fail loudly.
- **Seed reveal is unguarded when no passcode is set**: `DeviceAuth.swift:16-19` calls success when biometrics cannot evaluate. Refuse or warn.
- **No App Switcher privacy cover**: balances and chats end up in the snapshot. `KaChatApp.swift:182-212, 319`. Blur on `.inactive`.
- **Child Mode PIN** is a single SHA-256 with no attempt counter. `ChildModeService.swift:108-112`. PBKDF2 plus backoff.
- **Logs** print full addresses and aliases and are bundled into the diagnostics export with the device name. `AppLog.swift:25`, `KaChatTransactionBuilder.swift:388-389`, `ChatService+Fetching.swift:574, 1842, 1965`, `KNSService.swift:930, 987`, `SettingsView.swift:922, 970-996`. Truncate addresses; use `model` not `name`. No keys, seeds or plaintext are logged.
- **ChangeNOW API key ships in Info.plist** and is extractable. `Info.plist:22`, `ChangeNowAPIClient.swift:84`. Fine if it is a public affiliate key; otherwise proxy it.
- Intents extension holds `keychain-access-groups` it never uses (`KaChatIntents.entitlements`); App Attest entitlement declared but only DeviceCheck is used; macOS sandbox keys sit in iOS entitlements while `SUPPORTS_MACCATALYST = YES` on every target. Remove the unused ones and confirm Mac availability is off in App Store Connect.
- `CryptoUtils.deriveKey` (`CryptoUtils.swift:46-55`) is a home-made KDF with no callers. Delete it.

### Stability and recovery
- **Lost Secure Enclave key after an encrypted-backup restore** leaves a wallet that cannot sign or decrypt but still routes to the main app. `KeychainService.swift:51-71, 798-802`, `WalletManager.swift:739-758`, `LaunchRouter.swift:21`. Require `hasPrivateKey() || hasSeedPhrase()` in `loadWallet`, otherwise route to a re-import screen.
- **Secure Enclave unavailable is a hard failure that leaves an orphan wallet record** and shows a raw keychain error. `KeychainService.swift:843-845`, `WalletManager.swift:1465-1471`, `CreateWalletView.swift:28-34`. Persist a random device id on failure, save the wallet record last, roll back on throw.
- **Silent `try?` on money-moving and destructive actions**: batch send from spending addresses, Delete Wallet, and six balance lookups that render a node outage as "0 KAS" (dangerous for cold storage). `ManageAddressesView.swift:1171-1173`, `SettingsView.swift:181`, `ColdStorageView.swift:2097, 2551`, `ContactsView.swift:1090, 1281, 4067`, `ChatDetailView.swift:3092`. Use do/catch with an alert; distinguish empty from failed.
- **Raw internals in about 40 user alerts** (`DecodingError`, `URLError`, "Keychain error:" prefixes). Only `ChatDetailView.displayErrorMessage` maps errors and it is private. Promote it to a shared `UserFacingError.message(for:)`.
- **Background fetch keeps working after expiration** and completes the task twice; `task as! BGAppRefreshTask`. `BackgroundTaskManager.swift:25, 49-66`. Hold the Task, cancel it in the handler, complete once.
- `precondition(wordList.count == 2048)` in `BIP39.swift:33, 44, 109` traps in release if the resource is missing; throw instead.
- **No seed verification step and no later backup reminder**; only a self-attest checkbox. `CreateWalletView.swift:185-204`. Add a 3-word confirmation and a persistent "not backed up" banner.
- **No offline UI**: `NetworkEpochMonitor.isOnline` feeds only two call sites and a 12 pt dot in Settings. Bind a banner in `MainTabView`.

### Performance and battery
Steady-state foreground traffic is about 150-250 indexer requests per minute plus the full block stream. Three items account for nearly all of it:
- **Foreground contact sweep**: 1 handshake request plus up to 40 contacts × 2 aliases every ~10 s, on top of the 2 s open-chat poll. With 40 contacts that is 250-480 requests per minute. `ChatService+Conversations.swift:210-266, 302-324`, `ChatService.swift:324, 334`. Gate it on the UTXO subscription being down or unverified, or go to a 30 s base with a rotating cap of 10-15 contacts.
- **Full-block gRPC stream at ~10 blocks/s** whenever any group exists or any room is wanted; each block is decoded, re-serialized and re-parsed once per handler. The code's own comment calls it the single biggest data consumer. `GroupChatService.swift:2074-2079, 2123`, `PublicChatService.swift:1327-1335, 1355`, `GRPCStreamConnection.swift:806`. Parse once and pass a slim struct; longer term replace with indexer polling or `notifyVirtualChainChanged`.
- **Public-chat store reads whole rooms on the main thread** every 20 s (no fetch limit, `performAndWait`) and prunes all channels on main every 30 s. `PublicChatStore.swift:345-372, 651-700`, `PublicChatService.swift:232, 245, 510, 673, 829, 1472`, `PublicChatChannelView.swift:143-157`. Use an id-only fetch on a background context, a windowed fetch, and an async prune.
- Group catch-up fan-out: about 28 requests per minute for 3 groups of 8. `ChatService+Conversations.swift:250-256`. Batch member ids or space to 2-3 min while the block stream is live.
- `conversations` publishes with a synthesized `Equatable` over every message window; every message re-renders every observer. `ChatService.swift:41`, `Models.swift:462-476`, `ChatListView.swift:371`. Custom cheap `==`.
- Sync `performAndWait` in `currentStoreDiagnostics` (`MessageStore.swift:2422-2450`) and `migrateToReadMarkersIfNeeded` (`:1422-1450`, runs on every app-active). Use `perform`.
- Price history series (up to 6000 points per range × currency × pair) persisted in UserDefaults, rewritten whole on each write. `PortfolioViewModel.swift:809-811`. Move to a file in Application Support.
- `NodePoolService.updatePoolStats` publishes every 5 s regardless of tab; chess publishes `now` at 5 Hz. `NodePoolService.swift:1155-1170`, `ChessTournamentService.swift:15, 70-77`. Assign on change; use `TimelineView` for clocks.
- Temp files without cleanup: `MessageBubbleView.swift:2582, 2678`, `ChatDetailView.swift:3777, 4202, 4385`.

### Deletion and data lifecycle
- **Delete Wallet** unregisters push and clears keychain, contacts and rows, but leaves the per-wallet SQLite file, `call_contacts`, `groups`, `groupOwnTxIds`, `ownPrimaryKNSDomain`, KaPosts drafts and the node registry; the remote Nextcloud archive and app password are not removed. `WalletManager.swift:439-481`, `SharedDataManager.swift:604-623`, `MessageStore.swift:84-98`, `NextcloudService.swift:403-408, 1054`. Wipe the rest, delete the file, and offer to delete the archive and revoke the app password (`DELETE /ocs/v2.php/core/apppassword`).
- The Delete Wallet copy should say push registration on KaChat's server is removed and that on-chain posts and messages cannot be deleted. Apple accepts this for blockchain data when disclosed. `SettingsView.swift:175-186`.

### Store metadata and polish
- Add `NSLocalNetworkUsageDescription` (users can enter LAN node and Nextcloud hosts; WebRTC gathers host candidates). Without it iOS silently denies LAN traffic.
- `LSApplicationCategoryType = productivity` while the store category will be Finance or Social; align. `project.pbxproj:1905`.
- All three 1024 pt icons have alpha; Xcode flattens them today, but keep an eye out for ITMS-90717.
- Localization is partial: 983 `Text("...")` literals versus 700 catalog entries; German is missing 60 keys; the notification extension lacks `id.lproj`. List only meaningfully complete languages in App Store Connect.
- Ecosystem directory links to `kasplay.fun`; confirm it is not real-money gambling (Guideline 5.3).
- Support and report addresses are a personal Gmail in four places (`ContactsView.swift:1417, 1530`, `KaPostsView.swift:5090`, `GiftService.swift:38`). Use `support@kachat.app`.
- No acknowledgements screen and the vendored Opus has no LICENSE file. Opus and WebRTC are BSD-3 and require the notice to ship. Add `external/opus/COPYING` and a Settings > About > Open Source Licenses page.
- The XCTest target on disk (`KaChatTests/KaChatCoreTests.swift`) is not in the project, and the 17 `scripts/test_*.swift` have no runner. Add the target, run tests in Xcode Cloud, add `scripts/run_tests.sh`.
- No CHANGELOG; the README does not mention calls, chess tournaments, portfolio charts or translation.
- Dynamic Type: 173 fixed `.font(.system(size:))` in Views, none scaled. Worst on Portfolio balances (34 pt) and Settings (44 pt). Use `@ScaledMetric`.
- Accessibility: delivery state in the chat list is a colour-only glyph with no label; several icon-only toolbar buttons have no label; zero `.accessibilityHint` repo-wide. `ChatListView.swift:857-904, 1406, 1424-1437`, `ChatDetailView.swift:934, 3545, 3583`.

## 3. Verified in order
- Keychain: every write is `AfterFirstUnlockThisDeviceOnly` and non-synchronizable; seed, private key, group bags and the Child Mode record are Secure Enclave wrapped; the historical iCloud-synced Nextcloud credential is scrubbed; no key material in UserDefaults, files, App Group or pasteboard; the private key copy is local-only with a 30 s expiry.
- Cryptography: fresh ephemeral key and random 12-byte nonce with HKDF and ChaCha20-Poly1305; BIP39 entropy from `SecRandomCopyBytes` with CommonCrypto PBKDF2; group cipher uses AAD-bound AEAD with a per-device counter preserved across restores and Schnorr-signed control payloads; backup envelope is AES-256-GCM; Child Mode compare is constant-time; push auth signs a server nonce; KaPosts signatures are domain-separated.
- Network: no ATS exceptions; `http://` refused in Settings and Nextcloud connect; TLS nodes use system trust with SNI.
- Input: one strict deep-link parser with host allowlist; message taps open only http(s) or routed internal links; QR scans reduce to an address; the single WKWebView has no JavaScript bridge; the share extension only writes to the App Group queue.
- No analytics, ads or crash SDKs; no IDFA, IDFV, ATT or MetricKit. Nothing qualifies as tracking.
- Privacy manifests exist in all five targets with the UserDefaults reason declared; no other required-reason API is used.
- Usage strings present and specific for Camera, Microphone, Contacts, Face ID and Siri. Background modes all justified and the BGTask identifier matches. VoIP pushes are reported to CallKit synchronously and registration is skipped where CallKit is unavailable.
- Entitlements consistent across targets; `applinks:kachat.app` has a valid AASA listing both team IDs.
- Guideline 3.1.5: no mining, chess has no stakes, Swap names ChangeNOW and requires its terms checkbox.
- Release build settings sane: dSYM, whole-module, assertions off, testability off, versions shared through `Version.xcconfig`. No `print`, TODO or commented-out code; no orphan files; `Package.resolved` fully pinned.
- Task lifecycle, timers and observers are cleaned up; retries use capped exponential backoff with jitter; caches are bounded; chat lists are paged and lazy; no `try!` or `unowned`.

## 4. Privacy label, in short
Collected and linked to the user: Identifiers (Kaspa address, wallet public key, KaPosts public key, push and DeviceCheck tokens), Contacts (the contact address list, sent to nodes, indexer, push server and KNS), User Content (posts sent for translation; messages as ciphertext), Financial Info (transaction history via addresses, swap amounts and payout address). Not linked: Coarse Location (IP-derived, third party). Not collected: usage data, diagnostics. Used for tracking: nothing.

Servers per user: push registration record (deletable in-app), scheduled posts (cancellable), request logs at the indexer (no API), KNS primary name and profile image (set via API, no delete), the user's own Nextcloud archive and media (not deleted by the app), ChangeNOW swap records (none). On-chain data is permanent and must be disclosed as such.
