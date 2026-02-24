import SwiftUI
import AVFoundation
import UserNotifications

@main
struct KaChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var contactsManager = ContactsManager.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var giftService = GiftService.shared
    @State private var pendingOutboundShareId: String?
    @State private var isProcessingOutboundShare = false
    @Environment(\.scenePhase) private var scenePhase

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
            ReadStatusSyncManager.shared.flushPendingUpdates()
            // Force immediate CloudKit export before backgrounding
            MessageStore.shared.flushCloudKitExport()
            // Checkpoint WAL when going to background to reduce file size
            MessageStore.shared.checkpointWAL()
        case .active:
            // Cancel background fetch when app becomes active (we'll poll normally)
            BackgroundTaskManager.shared.cancelBackgroundFetch()
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
            Task {
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
                    ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                }
                // Run catch-up sync with push-reliability gating.
                await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)

                // One-time migration to per-device read markers (only when store is ready)
                if MessageStore.shared.isStoreLoaded && MessageStore.shared.currentWalletAddress != nil {
                    ReadStatusSyncManager.shared.runMigrationIfNeeded()
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
        guard !cleanedText.isEmpty else {
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
                try await chatService.sendMessage(to: contact, content: cleanedText)
            } catch {
                NSLog("[Share] Auto-send failed for %@, saved as draft: %@",
                      String(share.contactAddress.suffix(10)),
                      error.localizedDescription)
                chatService.setDraft(cleanedText, for: share.contactAddress)
            }
        } else {
            chatService.setDraft(cleanedText, for: share.contactAddress)
        }

        SharedDataManager.removeOutboundShare(id: share.id)
        pendingOutboundShareId = nil
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

            if sender == ourAddress || (isActiveConversation && UIApplication.shared.applicationState == .active) {
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
        // The threadIdentifier contains the contact address
        let contactAddress = response.notification.request.content.threadIdentifier
        if !contactAddress.isEmpty {
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
    static let showGiftClaim = Notification.Name("showGiftClaim")
}
