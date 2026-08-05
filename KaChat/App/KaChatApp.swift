import SwiftUI
import AVFoundation
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
    @StateObject private var broadcastService = BroadcastService.shared
    @StateObject private var groupChatService = GroupChatService.shared
    @State private var pendingOutboundShareId: String?
    @State private var isProcessingOutboundShare = false
    @State private var lastActiveResyncAt: Date?
    @State private var hasCompletedFirstActiveTransition = false
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the heavier resync work (node pool reconnect
    /// sweep, CloudKit fetch + catch-up sync) - only things that must run every single time
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
                .environmentObject(broadcastService)
                .environmentObject(groupChatService)
                .onAppear {
                    ChatService.shared.settingsViewModel = settingsViewModel
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
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
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
            // Flush any pending read status updates to CloudKit before backgrounding
            appDelegate.beginBackgroundFlushIfNeeded()
            ReadStatusSyncManager.shared.flushPendingUpdates()
            // Flush the debounced chat-list snapshot write immediately too, rather than leaving
            // it in-flight for a 300ms timer that iOS could suspend the process before firing.
            ChatService.shared.chatListSnapshotPersistTask?.cancel()
            ChatService.shared.persistChatListSnapshotIfPossible()
            // Force immediate CloudKit export before backgrounding
            MessageStore.shared.flushCloudKitExport()
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

            let isFirstActiveTransition = !hasCompletedFirstActiveTransition
            hasCompletedFirstActiveTransition = true
            // On cold launch specifically, every cache (KNS avatars, message-preview parsing,
            // image decoding) is empty, node pool/CloudKit/catch-up sync all kick off at once,
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
            // Refresh CloudKit first to pick up messages from other devices
            // Then sync messages that may have arrived while backgrounded
            if shouldRunHeavyResync {
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    // Fetch CloudKit changes to get messages sent from other devices
                    let settings = AppSettings.load()
                    if settings.storeMessagesInICloud {
                        #if targetEnvironment(macCatalyst)
                        let cloudKitImportTimeout: TimeInterval = 12.0
                        #else
                        let cloudKitImportTimeout: TimeInterval = 6.0
                        #endif
                        await MessageStore.shared.fetchCloudKitChanges(
                            reason: "app-active",
                            timeout: cloudKitImportTimeout
                        )
                        // Sync read statuses from CloudKit (picks up reads from other devices)
                        await ReadStatusSyncManager.shared.syncFromCloudKit()
                        // Load any CloudKit-synced messages before indexer sync
                        await ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                    }
                    // Run catch-up sync with push-reliability gating.
                    await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)

                    // One-time migration to per-device read markers (only when store is ready)
                    if MessageStore.shared.isStoreLoaded && MessageStore.shared.currentWalletAddress != nil {
                        ReadStatusSyncManager.shared.runMigrationIfNeeded()
                    }
                }
                // Group catch-up (including "you were added to a group" control messages) runs in
                // its OWN task, NOT serialized behind the cold-start grace + CloudKit import above,
                // so a newly-joined group appears in the list within ~1 network round trip instead
                // of the ~10s that serialization caused.
                Task {
                    await GroupChatService.shared.performCatchUpSync()
                }
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
        guard url.scheme?.lowercased() == "kachat",
              url.host?.lowercased() == "share",
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

    @MainActor
    private func processPendingOutboundShareIfNeeded() async {
        guard !isProcessingOutboundShare else { return }
        guard walletManager.currentWallet != nil else { return }

        if pendingOutboundShareId == nil {
            // Fallback path when Share Extension couldn't open URL directly.
            pendingOutboundShareId = SharedDataManager.getOutboundShares().last?.id
        }

        guard let shareId = pendingOutboundShareId else { return }

        isProcessingOutboundShare = true
        defer { isProcessingOutboundShare = false }

        SharedDataManager.pruneOutboundShares()
        guard let share = SharedDataManager.getOutboundShare(id: shareId) else {
            pendingOutboundShareId = nil
            return
        }

        let cleanedText = share.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard share.hasSendableContent else {
            SharedDataManager.removeOutboundShare(id: share.id)
            pendingOutboundShareId = nil
            return
        }

        let contact = contactsManager.getContact(byAddress: share.contactAddress)
            ?? contactsManager.getOrCreateContact(address: share.contactAddress)

        chatService.pendingChatNavigation = share.contactAddress
        NotificationCenter.default.post(
            name: .openChat,
            object: nil,
            userInfo: ["contactAddress": share.contactAddress]
        )

        if share.autoSend {
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
                if !cleanedText.isEmpty {
                    chatService.setDraft(cleanedText, for: share.contactAddress)
                }
            }
        } else {
            if !cleanedText.isEmpty {
                chatService.setDraft(cleanedText, for: share.contactAddress)
            }
        }

        SharedDataManager.removeOutboundShare(id: share.id)
        pendingOutboundShareId = nil
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
    private var backgroundFlushTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Orientation policy per device: iPhone is hard-locked to portrait; iPad may rotate to any
    /// orientation. This is the authoritative runtime source for supported orientations (it
    /// overrides the Info.plist keys), so iPhone never rotates into landscape regardless of the
    /// device's rotation lock setting, while iPad follows the device as usual.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// Requests a few extra seconds of background execution time so the debounced read-marker
    /// and CloudKit export writes triggered on backgrounding (both `context.perform`, not
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
        // Set notification delegate to handle foreground notifications
        UNUserNotificationCenter.current().delegate = self

        // Register background task handler
        BackgroundTaskManager.shared.registerBackgroundTasks()

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

            if sender == ourAddress || ((isActiveConversation || isActiveGroup) && UIApplication.shared.applicationState == .active) {
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
        // The threadIdentifier contains the contact address, "broadcast:<channel>" for a
        // broadcast room notification (see `BroadcastService.notifyIfEnabled`), or
        // "group:<groupId>" for a group chat notification.
        let threadIdentifier = response.notification.request.content.threadIdentifier
        if threadIdentifier.hasPrefix("broadcast:") {
            let channel = String(threadIdentifier.dropFirst("broadcast:".count))
            if !channel.isEmpty {
                // Store pending navigation for cold start scenario
                Task { @MainActor in
                    BroadcastService.shared.pendingBroadcastNavigation = channel
                }

                // Also post notification for already-running views
                NotificationCenter.default.post(
                    name: .openBroadcast,
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

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    static let openBroadcast = Notification.Name("openBroadcast")
    static let openGroup = Notification.Name("openGroup")
    static let showGiftClaim = Notification.Name("showGiftClaim")
}
