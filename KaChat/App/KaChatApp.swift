import SwiftUI
import AVFoundation
import Intents
import UserNotifications
import UIKit

@main
struct KaChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var contactsManager = ContactsManager.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var giftService = GiftService.shared
    @StateObject private var publicChatService = PublicChatService.shared
    @StateObject private var groupChatService = GroupChatService.shared
    @State private var pendingOutboundShareId: String?
    @State private var isProcessingOutboundShare = false
    @State private var lastActiveResyncAt: Date?
    @State private var hasCompletedFirstActiveTransition = false
    /// A "call X on KaChat" that arrived (Contacts app, Siri, Recents) before the wallet was
    /// loaded; placed as soon as it is.
    @State private var pendingIntentCall: (address: String, video: Bool)?
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the heavier resync work (node pool reconnect
    /// sweep, catch-up sync) - only things that must run every single time
    /// regardless of how brief the background interval was (e.g. resuming a UTXO subscription
    /// that's unconditionally paused on every backgrounding) still do. Without this, quickly
    /// backgrounding and resuming (e.g. glancing at the app switcher for a second) re-fired this
    /// whole battery of MainActor-hopping tasks on every return, competing with the user's own
    /// taps for the MainActor's serial queue right as they started navigating - reading as
    /// laggy "surfing around" immediately after a quick resume.
    private let activeResyncDebounce: TimeInterval = 15

    init() {
        // Warm up audio session and crypto on background thread to avoid first-interaction lag
        Task.detached(priority: .utility) {
            await Self.warmUp()
        }
        // Touch the (lazy) Nextcloud singleton so its lifecycle observers — the on-background
        // auto-backup and the launch catch-up — are registered from the very first launch
        // moment, not only after the user first visits a screen that references it.
        _ = NextcloudService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(contactsManager)
                .environmentObject(chatService)
                .environmentObject(settingsViewModel)
                .environmentObject(pushManager)
                .environmentObject(giftService)
                .environmentObject(publicChatService)
                .environmentObject(groupChatService)
                .onAppear {
                    ChatService.shared.settingsViewModel = settingsViewModel
                    applyWindowAppearanceOverride()
                    if #available(iOS 16.0, macCatalyst 16.0, *) {
                        KaChatShortcutsProvider.updateAppShortcutParameters()
                    }
                    if walletManager.currentWallet != nil {
                        Task {
                            await contactsManager.bootstrapSystemContactsIfNeeded()
                        }
                    }
                }
                .onChange(of: walletManager.currentWallet?.publicAddress) { newValue in
                    guard newValue != nil else { return }
                    Task {
                        await contactsManager.bootstrapSystemContactsIfNeeded()
                        await processPendingOutboundShareIfNeeded()
                    }
                    if let pending = pendingIntentCall {
                        pendingIntentCall = nil
                        placeIntentCall(address: pending.address, video: pending.video)
                    }
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal links (https://kachat.app/post/<txid>, and the old duckdns host) - same router.
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                    // "Call X with KaChat" from the Contacts app, Siri, or Recents - resolved
                    // by the KaChatIntents extension, placed here.
                    handleStartCallActivity(activity)
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .onChange(of: settingsViewModel.settings.appearance) { _ in
                    applyWindowAppearanceOverride()
                }
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    /// `.preferredColorScheme` only themes SwiftUI content — the UIKit layer underneath (the
    /// window background visible around sheet-presentation edges, the keyboard, share sheets,
    /// UIKit pickers) still follows the DEVICE appearance. With the app forced dark on a
    /// light-mode device, that mismatch showed as white edges peeking out around presented
    /// sheets. Overriding the windows' interface style makes the whole window chrome match.
    private func applyWindowAppearanceOverride() {
        let style: UIUserInterfaceStyle
        switch settingsViewModel.settings.appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                // The tab bar at the bottom kept the OLD theme's colours after a switch until
                // the app was relaunched: UIKit caches its resolved appearance and does not
                // re-resolve it for a window override change. Walking the bar and re-applying
                // the (dynamic-colour) appearance forces the repaint.
                Self.refreshTabBars(in: window.rootViewController)
            }
        }
    }

    private static func refreshTabBars(in root: UIViewController?) {
        guard let root else { return }
        var queue: [UIViewController] = [root]
        while let controller = queue.popLast() {
            if let tabs = controller as? UITabBarController {
                let appearance = UITabBarAppearance()
                appearance.configureWithDefaultBackground()
                tabs.tabBar.standardAppearance = appearance
                tabs.tabBar.scrollEdgeAppearance = appearance
                tabs.tabBar.setNeedsLayout()
                tabs.tabBar.layoutIfNeeded()
            }
            queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { queue.append(presented) }
        }
    }

    /// The Intents extension resolved whom to call and handed over; the activity carries the
    /// KaChat address (or the linked system contact) and whether video was asked for.
    private func handleStartCallActivity(_ activity: NSUserActivity) {
        let info = activity.userInfo ?? [:]
        let intent = activity.interaction?.intent as? INStartCallIntent
        let person = intent?.contacts?.first
        let video = (info["video"] as? Bool) ?? (intent?.callCapability == .videoCall)
        var address = (info["address"] as? String) ?? person?.customIdentifier ?? person?.personHandle?.value
        if address == nil || contactsManager.getContact(byAddress: address ?? "") == nil,
           let systemId = (info["systemContactId"] as? String) ?? person?.contactIdentifier,
           let linked = contactsManager.contacts.first(where: { $0.systemContactId == systemId }) {
            address = linked.address
        }
        guard let address else { return }
        if walletManager.currentWallet == nil {
            pendingIntentCall = (address, video)
            return
        }
        placeIntentCall(address: address, video: video)
    }

    private func placeIntentCall(address: String, video: Bool) {
        guard let contact = contactsManager.getContact(byAddress: address) else { return }
        if contact.callsEnabled == true {
            CallService.shared.startCall(with: contact, video: video)
        } else {
            // Calls are not yet allowed with this person: land in the chat, where the call
            // button asks to enable them.
            chatService.pendingChatNavigation = contact.address
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": contact.address])
        }
    }

    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            // Persist any debounced message draft immediately so it survives termination.
            ChatService.shared.flushPendingDraftSave()
            KaPostsNotificationService.shared.stop()
            // No indexer sweeping while backgrounded - the push / background fetch paths own that.
            ChatService.shared.stopForegroundContactSweep()
            ChatService.shared.stopActiveChatPollForBackground()
            // Schedule background fetch when app goes to background
            if settingsViewModel.settings.backgroundFetchEnabled {
                BackgroundTaskManager.shared.scheduleBackgroundFetch()
            }
            // Sync contacts to shared container for notification extension
            SharedDataManager.syncContactsForExtension()
            SharedDataManager.syncWalletAddressForExtension()
            SharedDataManager.syncNotificationSettingsForExtension()
            if settingsViewModel.settings.notificationMode == .remotePush {
                ChatService.shared.pauseUtxoSubscriptionForRemotePush()
            }
            // Flush any pending read status updates to the store before backgrounding
            appDelegate.beginBackgroundFlushIfNeeded()
            ReadStatusSyncManager.shared.flushPendingUpdates()
            // Flush the debounced chat-list snapshot write immediately too, rather than leaving
            // it in-flight for a 300ms timer that iOS could suspend the process before firing.
            ChatService.shared.chatListSnapshotPersistTask?.cancel()
            ChatService.shared.persistChatListSnapshotIfPossible()
            // Checkpoint WAL when going to background to reduce file size
            MessageStore.shared.checkpointWAL()
            // Give the async saves above a moment to actually land before releasing the
            // background task, since iOS can suspend the process as soon as it ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                appDelegate.endBackgroundFlushIfNeeded()
            }
        case .active:
            // Cancel background fetch when app becomes active (we'll poll normally)
            BackgroundTaskManager.shared.cancelBackgroundFetch()
            // KaPosts social pings (likes/replies/quotes on your posts) - local-notification
            // poller, chat-style. Runs only while the app is active.
            KaPostsNotificationService.shared.start()
            // Foreground 1:1 indexer sweep (defense-in-depth next to the utxosChanged push and the
            // app-active catch-up sync below). No-op when no wallet is loaded yet - startPolling()
            // starts it once the wallet/store are ready.
            ChatService.shared.startForegroundContactSweep()
            // And the 2s open-chat poll, if a conversation was open when we went to background.
            ChatService.shared.resumeActiveChatPollIfNeeded()

            // Keep the Share Extension's data sources fresh on activation too - previously
            // contacts synced only on .background, so a fresh install that had never
            // backgrounded showed an empty contact list in the share sheet.
            SharedDataManager.syncContactsForExtension()
            SharedDataManager.syncWalletAddressForExtension()

            let isFirstActiveTransition = !hasCompletedFirstActiveTransition
            hasCompletedFirstActiveTransition = true
            // On cold launch specifically, every cache (KNS avatars, message-preview parsing,
            // image decoding) is empty, node pool/catch-up sync all kick off at once,
            // and the user is most likely to immediately start navigating around (e.g. opening a
            // chat and coming right back out) - all of that is MainActor-bound work (every
            // service here is @MainActor), so it directly competes with the user's own taps and
            // the chat list's own first-render work for the main thread's attention, which showed
            // up as a real freeze/black-screen specifically right after launch, getting harder to
            // reproduce once things warmed up. This grace period doesn't skip any of the sync
            // work below, just lets the very first render settle before it starts contending for
            // the main thread.
            let coldStartGraceNanos: UInt64 = isFirstActiveTransition ? 2_000_000_000 : 0

            let shouldRunHeavyResync = lastActiveResyncAt.map {
                Date().timeIntervalSince($0) > activeResyncDebounce
            } ?? true
            if shouldRunHeavyResync {
                lastActiveResyncAt = Date()
                // A batch of gRPC connections can die silently while backgrounded/asleep (the OS
                // tears down sockets, and the stream-completion callback that would normally
                // self-reconnect can be suspended along with the rest of the app) - reconnect any
                // that are dead right now instead of waiting for the next request to lazily discover
                // and fix just that one endpoint.
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await NodePoolService.shared.reconnectStaleConnections()
                }
            }
            if walletManager.currentWallet != nil {
                Task {
                    await contactsManager.bootstrapSystemContactsIfNeeded()
                }
            }
            // Process any messages decrypted by notification extension
            Task {
                await pushManager.processPendingMessages()
            }
            Task {
                await processPendingOutboundShareIfNeeded()
            }
            // Sync messages that may have arrived while backgrounded
            if shouldRunHeavyResync {
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    // Run catch-up sync with push-reliability gating.
                    await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)

                    // One-time migration to per-device read markers (only when store is ready)
                    if MessageStore.shared.isStoreLoaded && MessageStore.shared.currentWalletAddress != nil {
                        ReadStatusSyncManager.shared.runMigrationIfNeeded()
                    }
                }
                // Own-address receive catch-up: diff spending/cold-storage balances against the
                // persisted baseline and notify for external receipts that landed while away
                // (internally debounced; first run only seeds the baseline).
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await AddressActivityNotifier.shared.runCatchUpIfNeeded()
                }
            }
            // Group catch-up (including "you were added to a group" control messages) runs on
            // EVERY foreground, NOT gated by the heavy-resync debounce above - otherwise a group
            // you were just added to on another device would not appear until the debounce window
            // elapsed and the app was re-activated. It is a cheap, cursor-based single round trip
            // that runs in its own task, so a newly-joined group appears within ~1 network hop.
            Task {
                await GroupChatService.shared.performCatchUpSync()
            }
            if settingsViewModel.settings.notificationMode == .remotePush {
                Task {
                    await ChatService.shared.resumeUtxoSubscriptionForRemotePush()
                }
                pushManager.refreshRegistrationIfNeeded()
            }
            SharedDataManager.syncWalletAddressForExtension()
            SharedDataManager.syncNotificationSettingsForExtension()
            SharedDataManager.syncGroupsForExtension()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Every in-app target link - KaPosts posts and public chat rooms, in both their
        // `kachat://` and `https://kachat.duckdns.org/...` forms - is parsed and validated in
        // ONE place (`KaChatInternalLink.parse`) and routed through ONE place
        // (`KaChatLinkRouter.open`), shared with the in-chat preview cards so a tapped card and
        // a tapped system link can never diverge.
        if let link = KaChatInternalLink.parse(url) {
            KaChatLinkRouter.open(link)
            return
        }

        guard url.scheme?.lowercased() == "kachat" else { return }

        // kachat://portfolio - the Home Screen widget's tap target. Staged as well as posted:
        // on a cold start this runs while the app is still on the loading route, where nothing
        // is listening (see PendingTabRoute).
        if url.host?.lowercased() == "portfolio" {
            PendingTabRoute.pending = .portfolio
            NotificationCenter.default.post(name: .openPortfolio, object: nil)
            return
        }

        guard url.host?.lowercased() == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shareId = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !shareId.isEmpty else {
            return
        }

        pendingOutboundShareId = shareId
        Task {
            await processPendingOutboundShareIfNeeded()
        }
    }

    /// Drains the Share Extension's outbound queue. Auto-send shares (composed and confirmed in
    /// the extension's quick-reply popup) are delivered on-chain IMMEDIATELY, with no user
    /// interaction - the extension's confirmation screen already promised "sends the moment
    /// KaChat opens". Pre-fill shares ("Edit in KaChat instead") stage the content in the chat
    /// composer. Runs on every activation and on the kachat://share deep link, so the queue is
    /// processed whether or not the extension's best-effort app-open worked.
    @MainActor
    private func processPendingOutboundShareIfNeeded() async {
        guard !isProcessingOutboundShare else { return }
        guard walletManager.currentWallet != nil else { return }

        isProcessingOutboundShare = true
        defer { isProcessingOutboundShare = false }

        SharedDataManager.pruneOutboundShares()
        // Oldest first so multiple queued messages to the same contact arrive in the order the
        // user shared them. The deep-linked share id (if any) is just one of these; processing
        // the whole queue also covers shares from earlier failed app-open attempts.
        let shares = SharedDataManager.getOutboundShares().sorted { $0.createdAtMs < $1.createdAtMs }
        pendingOutboundShareId = nil
        guard !shares.isEmpty else { return }

        for share in shares {
            let cleanedText = share.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard share.hasSendableContent else {
                SharedDataManager.removeOutboundShare(id: share.id)
                continue
            }

            let contact = contactsManager.getContact(byAddress: share.contactAddress)
                ?? contactsManager.getOrCreateContact(address: share.contactAddress)

            chatService.pendingChatNavigation = share.contactAddress

            if share.autoSend {
                // Land in the chat so the user watches the queued message send for real -
                // pending bubble, delivery state, the works.
                NotificationCenter.default.post(
                    name: .openChat,
                    object: nil,
                    userInfo: ["contactAddress": share.contactAddress]
                )
                do {
                    if !cleanedText.isEmpty {
                        try await chatService.sendMessage(to: contact, content: cleanedText)
                    }
                    if let image = share.image {
                        try await sendSharedImage(image, to: contact)
                    }
                } catch {
                    AppLog.log("[Share] Auto-send failed for %@: %@",
                          String(share.contactAddress.suffix(10)),
                          error.localizedDescription)
                    // Don't lose the message: fall back to staging it as the chat's draft so
                    // the user can retry with one tap.
                    if !cleanedText.isEmpty {
                        chatService.setDraft(cleanedText, for: share.contactAddress)
                    }
                }
            } else {
                // Pre-fill path: land the user in the chat with the shared content staged in the
                // composer. Draft + image must be staged BEFORE posting .openChat - the notification
                // is delivered synchronously and ChatDetailView reads both while handling it.
                if !cleanedText.isEmpty {
                    chatService.setDraft(cleanedText, for: share.contactAddress)
                }
                if let image = share.image,
                   let fileURL = SharedDataManager.outboundShareImageFileURL(for: image),
                   let imageData = try? Data(contentsOf: fileURL) {
                    chatService.stagePendingShareImage(imageData, for: share.contactAddress)
                }
                NotificationCenter.default.post(
                    name: .openChat,
                    object: nil,
                    userInfo: ["contactAddress": share.contactAddress]
                )
            }

            SharedDataManager.removeOutboundShare(id: share.id)
        }
    }

    private func sendSharedImage(_ image: SharedOutboundShare.ImageAttachment, to contact: Contact) async throws {
        guard let fileURL = SharedDataManager.outboundShareImageFileURL(for: image) else {
            throw KasiaError.networkError("Could not locate shared image")
        }

        let imageData = try Data(contentsOf: fileURL)
        guard let uiImage = UIImage(data: imageData) else {
            throw KasiaError.networkError("Shared image could not be decoded")
        }

        let preparedImage = try ImagePrep.prepareForChatMessage(uiImage)
        try await chatService.sendImage(
            to: contact,
            imageData: preparedImage.data,
            fileName: preparedImage.fileName,
            mimeType: preparedImage.mimeType
        )
    }

    /// Pre-initialize heavy components to avoid lag on first user interaction
    private static func warmUp() async {
        // Warm up audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])

        // Warm up crypto library with dummy operation
        let dummyKey = Data(repeating: 0x01, count: 32)
        _ = try? KasiaCipher.encrypt("warmup", recipientPublicKey: dummyKey)
    }
}

// MARK: - App Delegate for Notification and Background Task Handling
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Which KaPosts pushes the reader still wants shown, by the five Settings switches.
    ///
    /// The same decision as `NotificationService.kaPostsPushAllowed` in the extension, kept in
    /// step by hand because the two targets share no source. `kaposts_kind` is the field the
    /// server should send; failing that the body is matched against the exact English phrases
    /// PUSH_EXTENSIONS.md §3 specifies - server-generated and unlocalized, so a fixed set. An
    /// unrecognised push is shown rather than swallowed.
    static func kaPostsPushAllowed(userInfo: [AnyHashable: Any], body: String, settings: AppSettings) -> Bool {
        let key: String
        if let explicit = userInfo["kaposts_kind"] as? String {
            switch explicit {
            case "vote_up": key = "likes"
            case "vote_down": key = "dislikes"
            case "reply": key = "comments"
            case "quote", "repost": key = "reposts"
            case "follow": key = "follows"
            case "mention": key = "mentions"
            default: return true
            }
        } else {
            let lowered = body.lowercased()
            if lowered.contains("disliked your") { key = "dislikes" }
            else if lowered.contains("liked your") { key = "likes" }
            else if lowered.contains("replied to your") { key = "comments" }
            else if lowered.contains("quoted your") || lowered.contains("reposted your") { key = "reposts" }
            else if lowered.contains("followed you") { key = "follows" }
            else if lowered.contains("mentioned you") { key = "mentions" }
            else { return true }
        }
        switch key {
        case "likes": return settings.kaPostsNotifyLikes
        case "dislikes": return settings.kaPostsNotifyDislikes
        case "comments": return settings.kaPostsNotifyComments
        case "reposts": return settings.kaPostsNotifyReposts
        case "follows": return settings.kaPostsNotifyFollows
        case "mentions": return settings.kaPostsNotifyMentions
        default: return true
        }
    }

    private var backgroundFlushTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Orientation policy per device: iPhone is hard-locked to portrait; iPad may rotate to any
    /// orientation. This is the authoritative runtime source for supported orientations (it
    /// overrides the Info.plist keys), so iPhone never rotates into landscape regardless of the
    /// device's rotation lock setting, while iPad follows the device as usual.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// Requests a few extra seconds of background execution time so the debounced read-marker
    /// and snapshot writes triggered on backgrounding (both `context.perform`, not
    /// `performAndWait`, so they return before the save actually lands) get a chance to complete
    /// before iOS can suspend the process. Without this, backgrounding right after reading a chat
    /// can lose that write, resurrecting a stale "unread" position and wrong scroll anchor the
    /// next time the chat is opened.
    func beginBackgroundFlushIfNeeded() {
        endBackgroundFlushIfNeeded()
        backgroundFlushTaskId = UIApplication.shared.beginBackgroundTask(withName: "ReadStatusFlush") { [weak self] in
            self?.endBackgroundFlushIfNeeded()
        }
    }

    func endBackgroundFlushIfNeeded() {
        guard backgroundFlushTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlushTaskId)
        backgroundFlushTaskId = .invalid
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        // Set notification delegate to handle foreground notifications
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()

        // Register background task handler
        BackgroundTaskManager.shared.registerBackgroundTasks()

        // VoIP pushes (a closed app ringing) must be registered for at launch: a push that
        // launches the app is delivered to this registration.
        VoIPPushManager.shared.start()

        // The notification extension's copy of the notification switches is refreshed on every
        // launch, so an app update can never leave it stale or missing.
        SharedDataManager.syncNotificationSettingsForExtension()

        // Security hygiene: wipe the legacy plaintext shared-secret blob older releases left
        // in the App Group plist (see SharedDataManager.purgeLegacySharedSecretsIfPresent).
        SharedDataManager.purgeLegacySharedSecretsIfPresent()

        // Warm up keyboard in background to avoid first-tap delay
        // Delay slightly to ensure scene is ready (prevents "UIScene accessed before set" warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.warmUpKeyboard()
        }

        return true
    }

    // MARK: - APNs Token Handling

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

#if targetEnvironment(macCatalyst)
    func applicationShouldTerminateAfterLastWindowClosed(_ application: UIApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        ensureMainWindow(application)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        // Replace Close Window (Cmd+W) with Hide Window to keep the scene alive.
        // This avoids a full scene rebuild when the user clicks the dock icon.
        let hideCommand = UIKeyCommand(
            title: "Hide Window",
            action: #selector(hideActiveWindow),
            input: "W",
            modifierFlags: .command
        )
        let menu = UIMenu(title: "", options: .displayInline, children: [hideCommand])
        builder.replace(menu: .close, with: menu)
    }

    @objc func hideActiveWindow() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.isHidden = true
            }
        }
    }

    private func ensureMainWindow(_ application: UIApplication) {
        // First: try to unhide any hidden windows in connected scenes (instant)
        for scene in application.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let hiddenWindows = windowScene.windows.filter { $0.isHidden }
            if !hiddenWindows.isEmpty {
                for window in hiddenWindows {
                    window.isHidden = false
                    window.makeKeyAndVisible()
                }
                return
            }
            // Scene is connected and has visible windows — nothing to do
            if !windowScene.windows.isEmpty { return }
        }

        // No connected scene with windows — reactivate an existing session
        // (faster than creating a brand new one with nil)
        UIApplication.shared.requestSceneSessionActivation(
            application.openSessions.first,
            userActivity: nil,
            options: nil,
            errorHandler: nil
        )
    }
#endif

    /// Pre-load keyboard to avoid first-use delay
    private static func warmUpKeyboard() {
        // Guard against accessing scene before it's ready
        guard !UIApplication.shared.connectedScenes.isEmpty else {
            return
        }

        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []

        // Add to window hierarchy temporarily
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            textField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
            window.addSubview(textField)
            textField.becomeFirstResponder()

            // Remove after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textField.resignFirstResponder()
                textField.removeFromSuperview()
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            let sender = userInfo["sender"] as? String
            let ourAddress = WalletManager.shared.currentWallet?.publicAddress
            let activeAddress = ChatService.shared.activeConversationAddress
            let threadId = notification.request.content.threadIdentifier
            let settings = AppSettings.load()
            // Child Mode: never display KaPosts/public chat notifications. Registration already
            // drops the public chat channels + KaPosts pubkey (see PushNotificationManager), but a
            // push can still race the re-registration - suppress it client-side too.
            if settings.childModeEnabled, threadId == "kaposts" || threadId.hasPrefix("broadcast:") {
                completionHandler([])
                return
            }
            // The per-kind KaPosts switches. This is the only client-side gate that runs for
            // these pushes: they carry no mutable-content, so the notification service
            // extension's matching check never executes, and until the server honors the
            // kinds sent at registration a switched-off like still arrives while the app is in
            // the background. In the foreground, at least, it does not get a banner.
            if threadId == "kaposts", !Self.kaPostsPushAllowed(userInfo: userInfo,
                                                               body: notification.request.content.body,
                                                               settings: settings) {
                completionHandler([])
                return
            }
            let contactAddress = sender ?? (!threadId.isEmpty ? threadId : nil)
            let contact = contactAddress.flatMap { ContactsManager.shared.getContact(byAddress: $0) }
            let isActiveConversation = activeAddress != nil &&
                (activeAddress == sender || (!threadId.isEmpty && activeAddress == threadId))
            // Group push's threadIdentifier is "group:<groupId>" (see NotificationService.swift's
            // handleGroupPush) - mirrors the 1:1 check above using GroupChatService's own
            // currently-open-group tracking (GroupChatDetailView's .task/.onDisappear), which
            // already existed for the read-state auto-mark but was never consulted here.
            let isActiveGroup = threadId.hasPrefix("group:") &&
                GroupChatService.shared.activeGroupId == String(threadId.dropFirst("group:".count))
            // Public Chats follow the same one-rule policy: suppressed only while THAT room's
            // screen is open (thread id "public chat:<channel>" on local banners and pushes alike).
            let isActivePublicChat = threadId.hasPrefix("broadcast:") &&
                PublicChatService.shared.isViewing(channel: String(threadId.dropFirst("broadcast:".count)))
            // The push is the only banner source now (see `ChatService.localBannersEnabled`).
            // Three rules used to live here for the app's own local banners - dropping a push
            // whose txId a local banner had already claimed, deferring KaPosts pushes to the
            // in-app poller's banners, and dropping public chat pushes in the foreground because
            // the scan's banner covered them. With nothing posting locally, each of those would
            // have swallowed the only notification left, so they are gone. What remains is the
            // one rule that is about the reader, not the plumbing: no banner for the stream
            // they are looking at.
            if threadId == "kaposts" {
                if UIApplication.shared.applicationState == .active,
                   KaPostsNotificationService.shared.isNotificationsScreenVisible {
                    completionHandler([])
                    return
                }
                var options: UNNotificationPresentationOptions = [.banner, .badge]
                if settings.incomingNotificationSoundEnabled {
                    options.insert(.sound)
                } else if settings.incomingNotificationVibrationEnabled {
                    Haptics.impact(.light)
                }
                completionHandler(options)
                return
            }

            if sender == ourAddress || ((isActiveConversation || isActiveGroup || isActivePublicChat) && UIApplication.shared.applicationState == .active) {
                completionHandler([])
            } else if !settings.shouldDeliverIncomingNotification(for: contact) {
                completionHandler([])
            } else {
                var options: UNNotificationPresentationOptions = [.banner, .badge]
                if settings.shouldPlayIncomingNotificationSound(for: contact) {
                    options.insert(.sound)
                } else if settings.incomingNotificationVibrationEnabled {
                    Haptics.impact(.light)
                }
                completionHandler(options)
            }
        }

        Task {
            _ = await PushNotificationManager.shared.handleRemoteNotification(userInfo)
        }
    }

    // MARK: Quick reply (iPhone notification actions + Apple Watch)

    /// Category attached to every actionable message notification (1:1 and group, local and
    /// push). The text-input action gives iPhone its inline quick-reply field and Apple Watch
    /// its Reply button with dictation/scribble - no watch app needed, mirrored notifications
    /// inherit the actions automatically.
    static let messageCategoryId = "KACHAT_MESSAGE"
    static let replyActionId = "KACHAT_REPLY"

    private func registerNotificationCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: String(localized: "Reply"),
            options: [],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message")
        )
        let category = UNNotificationCategory(
            identifier: Self.messageCategoryId,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private enum QuickReplyError: Error {
        case noWallet
        case unknownTarget
    }

    /// Sends a quick-reply without any UI: iOS launches the app into the background for the
    /// action, so grab background time, make sure the wallet is loaded (keychain material is
    /// AfterFirstUnlock, so this works from the lock screen), and route by thread id. On any
    /// failure, post a notification so the reply isn't silently lost.
    private func handleQuickReply(
        text: String,
        threadIdentifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completionHandler()
            return
        }
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "kachat.quickreply") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        Task { @MainActor in
            defer {
                completionHandler()
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            do {
                if WalletManager.shared.currentWallet == nil {
                    await WalletManager.shared.loadWallet()
                }
                guard WalletManager.shared.currentWallet != nil else { throw QuickReplyError.noWallet }
                if threadIdentifier.hasPrefix("group:") {
                    let groupId = String(threadIdentifier.dropFirst("group:".count))
                    guard !groupId.isEmpty else { throw QuickReplyError.unknownTarget }
                    try await GroupChatService.shared.sendGroupMessage(trimmed, to: groupId)
                } else if !threadIdentifier.isEmpty,
                          let contact = ContactsManager.shared.getContact(byAddress: threadIdentifier) {
                    _ = ChatService.shared.getOrCreateConversation(for: contact)
                    try await ChatService.shared.sendMessage(to: contact, content: trimmed)
                } else {
                    throw QuickReplyError.unknownTarget
                }
            } catch {
                AppLog.log("%@", "[QuickReply] Send failed: \(error.localizedDescription)")
                postQuickReplyFailureNotification(threadIdentifier: threadIdentifier)
            }
        }
    }

    private func postQuickReplyFailureNotification(threadIdentifier: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reply not sent")
        content.body = String(localized: "Your reply couldn't be sent. Open KaChat to try again.")
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "quickreply-fail-\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            _ = await PushNotificationManager.shared.handleRemoteNotification(
                response.notification.request.content.userInfo
            )
        }
        // A tapped "Incoming call" alert: ring it now if the call is still live, or tell the
        // chat why not. A no-op for every push that is not an opening call message.
        let tappedUserInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            CallService.shared.handleCallNotificationTap(tappedUserInfo)
        }
        // The threadIdentifier contains the contact address, "public chat:<channel>" for a
        // public chat room notification (see `PublicChatService.notifyIfEnabled`), or
        // "group:<groupId>" for a group chat notification.
        let threadIdentifier = response.notification.request.content.threadIdentifier

        // Child Mode: a stray KaPosts/public chat notification tap (e.g. one delivered before the
        // mode was switched on, or a remote push that raced the re-registration) must not route
        // into the hidden features - land on the main Chats screen instead.
        if AppSettings.load().childModeEnabled,
           threadIdentifier == "kaposts" || threadIdentifier.hasPrefix("broadcast:") {
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // The scheduled-post reminder (local fallback): into KaPosts, which sends what is due
        // and shows the Scheduled screen.
        if threadIdentifier == "kaposts-scheduled" {
            KaPostsDeepLink.pendingOpenScheduled = true
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // KaPosts push (server thread-id "kaposts"): straight to the post's thread when the
        // payload names one, else into KaPosts with the Notifications screen opened.
        if threadIdentifier == "kaposts" {
            // A tapped push leaves Notification Center, so the poller's delivered-list check
            // can no longer see it - record its action txid (the request identifier is the
            // apns-collapse-id) in the displayed ledger so the next poll doesn't re-banner it.
            if response.notification.request.trigger is UNPushNotificationTrigger {
                let actionId = response.notification.request.identifier
                Task { @MainActor in
                    KaPostsNotificationService.shared.recordDisplayed(actionId: actionId)
                }
            }
            let userInfo = response.notification.request.content.userInfo
            if let postId = userInfo["postId"] as? String, !postId.isEmpty {
                KaPostsDeepLink.pendingPostTxId = postId
            } else {
                KaPostsDeepLink.pendingOpenNotifications = true
            }
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // Own-address activity (spending / cold-storage receive) notification tapped: these
        // are wallet events, not chats - the thread id must never fall through to the
        // contact-address branch below (it would stage a bogus pendingChatNavigation). Cold
        // storage has its own dock tab; a spending-address receipt lands on the wallet screen
        // (Portfolio, or Profile when Portfolio is hidden - MainTabView picks), which is where
        // the balance that just moved is shown. `PendingTabRoute` covers the cold start, where
        // the post below has no observer yet.
        if threadIdentifier == AddressActivityNotifier.notificationThreadIdentifier {
            let kind = response.notification.request.content.userInfo["kind"] as? String
            if kind == "cold" {
                PendingTabRoute.pending = .coldStorage
                NotificationCenter.default.post(name: .openColdStorage, object: nil)
            } else {
                PendingTabRoute.pending = .portfolio
                NotificationCenter.default.post(name: .openPortfolio, object: nil)
            }
            completionHandler()
            return
        }

        // Quick reply: send straight from the notification (long-press on iPhone, Reply on
        // Apple Watch) without opening the app UI.
        if response.actionIdentifier == Self.replyActionId,
           let textResponse = response as? UNTextInputNotificationResponse {
            handleQuickReply(
                text: textResponse.userText,
                threadIdentifier: threadIdentifier,
                completionHandler: completionHandler
            )
            return
        }
        if threadIdentifier.hasPrefix("broadcast:") {
            let channel = String(threadIdentifier.dropFirst("broadcast:".count))
            if !channel.isEmpty {
                // Store pending navigation for cold start scenario
                Task { @MainActor in
                    PublicChatService.shared.pendingPublicChatNavigation = channel
                }

                // Also post notification for already-running views
                NotificationCenter.default.post(
                    name: .openPublicChat,
                    object: nil,
                    userInfo: ["channel": channel]
                )
            }
        } else if threadIdentifier.hasPrefix("group:") {
            let groupId = String(threadIdentifier.dropFirst("group:".count))
            if !groupId.isEmpty {
                // Store pending navigation for cold start scenario
                Task { @MainActor in
                    GroupChatService.shared.pendingGroupNavigation = groupId
                }

                // Also post notification for already-running views
                NotificationCenter.default.post(
                    name: .openGroup,
                    object: nil,
                    userInfo: ["groupId": groupId]
                )
            }
        } else if threadIdentifier == "group" {
            // Undecryptable group push: NotificationService's `deliverGroupFallback` can only
            // tag it with the bare "group" thread id (it never learned WHICH group), so there's
            // no room to open. Land on the Groups list - the branch below would otherwise treat
            // "group" as a contact address and go nowhere at all.
            Task { @MainActor in
                GroupChatService.shared.pendingGroupListNavigation = true
            }
            NotificationCenter.default.post(name: .openGroup, object: nil, userInfo: [:])
        } else if !threadIdentifier.isEmpty {
            let contactAddress = threadIdentifier
            // Store pending navigation for cold start scenario
            Task { @MainActor in
                ChatService.shared.pendingChatNavigation = contactAddress
            }

            // Also post notification for already-running views
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contactAddress]
            )
        } else {
            // No thread id at all - a server push that predates (or drops) the thread-id
            // contract. Nothing to route by, so land on the main Chats screen rather than
            // leaving the user wherever the app happened to be.
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
        }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let handled = await PushNotificationManager.shared.handleRemoteNotification(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

/// Cold-start handoff for kachat://kapost/<txid> links - the notification alone is lost if
/// KaPostsView isn't mounted yet.
enum KaPostsDeepLink {
    static var pendingPostTxId: String?
    /// KaPosts push tapped without a specific post - open the Notifications screen on mount.
    static var pendingOpenNotifications = false
    /// The scheduled-post reminder tapped - open the Scheduled screen on mount.
    static var pendingOpenScheduled = false
}

/// Cold-start handoff for a notification tap whose whole destination IS a dock tab (wallet
/// receipts, cold-storage activity). The `.openPortfolio`/`.openColdStorage` posts those taps
/// make are delivered synchronously to whoever is listening RIGHT THEN - on a cold start that
/// is nobody, since the app is still on the loading/onboarding route and `MainTabView` hasn't
/// mounted. It consumes this on mount instead (`consumePendingNotificationRoute`); the
/// destinations that carry their own pending state (chat, group, room, post) don't need it.
enum PendingTabRoute {
    static var pending: AppTab?
}

/// The single place an already-validated `KaChatInternalLink` becomes navigation. Used by the
/// system URL router (`KaChatApp.handleIncomingURL`, for links tapped outside the app) AND by
/// the in-chat preview cards (`KaChatInternalLinkCardView`), so a link opens the same screen
/// whichever way the user reached it - and never bounces out to Safari for an in-app target.
enum KaChatLinkRouter {
    /// Any URL a user taps inside the app: a KaChat link (kachat.app, the old duckdns host, or
    /// the kachat:// scheme) goes straight to its post or room; everything else leaves the
    /// app as usual. The one call every "Open" button should make.
    @MainActor
    static func openAnywhere(_ url: URL) {
        if let link = KaChatInternalLink.parse(url) {
            open(link)
            return
        }
        UIApplication.shared.open(url)
    }

    @MainActor
    static func open(_ link: KaChatInternalLink) {
        switch link {
        case .kaPost(let txId):
            openKaPost(txId: txId)
        case .publicChatRoom(let channel):
            openPublicChatRoom(channel: channel)
        }
    }

    @MainActor
    private static func openKaPost(txId: String) {
        // Child Mode: KaPosts links (universal https://.../post/<txid> and kachat://kapost/...)
        // no-op to the main screen instead of opening the hidden feature.
        guard !AppSettings.load().childModeEnabled else {
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
            return
        }
        guard !txId.isEmpty else { return }
        // Cold-start handoff (KaPostsView may not be mounted yet) plus the live notification for
        // an already-mounted one - KaPostsView consumes whichever arrives.
        KaPostsDeepLink.pendingPostTxId = txId
        NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: ["txId": txId])
    }

    @MainActor
    private static func openPublicChatRoom(channel: String) {
        // Child Mode removes Public Chats entirely (see AppTab.isEnabled) - same no-op to the main
        // screen KaPosts links get, rather than opening a hidden feature by link.
        guard !AppSettings.load().childModeEnabled else {
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
            return
        }
        // Re-validate even though `KaChatInternalLink.parse` already did: this is the last gate
        // before a name from a pasted link can create a store row, and the router is callable
        // from anywhere.
        guard let normalized = KaChatInternalLink.normalizeAndValidateChannel(channel) else { return }
        // Curated rooms (Popular + the language rooms) always exist - just open them. Anything
        // else has to land in the user's own channel list first, exactly as if they'd typed the
        // name into "Join or Create a Channel", or the room screen would open something the
        // list screen doesn't know about.
        if !PublicChatService.indexedChannels.contains(normalized) {
            PublicChatService.shared.joinChannel(normalized)
        }
        PublicChatService.shared.pendingPublicChatNavigation = normalized
        NotificationCenter.default.post(
            name: .openPublicChat,
            object: nil,
            userInfo: ["channel": normalized]
        )
    }
}

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    /// Lands on the Profile tab with the KNS profile editor open. Posted from the KaPosts
    /// profile, whose Edit KNS Profile button routes here rather than rebuilding the editor:
    /// `KNSProfileEditorSheet` is driven by a spread of ProfileView's own state (domains,
    /// primary, in-flight set-primary), and a second copy of that would be a second thing to
    /// keep correct.
    static let openKNSProfileEditor = Notification.Name("openKNSProfileEditor")
    static let openKaPost = Notification.Name("openKaPost")
    static let openPortfolio = Notification.Name("openPortfolio")
    static let openColdStorage = Notification.Name("openColdStorage")
    static let openPublicChat = Notification.Name("openBroadcast")
    /// Open Customize Dock. Posted rather than pushed because that screen EDITS the dock, and the
    /// dock's tabs are the TabView's own children: changing placement rebuilds them, which
    /// destroys any navigation stack pushed inside one. Presented from MainTabView instead, above
    /// the TabView, where nothing it does to the dock can dismiss it.
    static let openCustomizeDock = Notification.Name("openCustomizeDock")
    static let openGroup = Notification.Name("openGroup")
    static let showGiftClaim = Notification.Name("showGiftClaim")
}
