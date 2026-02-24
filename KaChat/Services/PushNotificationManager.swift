import Foundation
import Combine
import UserNotifications
import UIKit
import DeviceCheck
import CryptoKit
import Security
import P256K

/// Manages push notification registration and indexer communication
@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    // MARK: - Published State

    @Published private(set) var isRegistered = false
    @Published private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    /// Number of addresses being watched for push notifications
    var watchedAddressesCount: Int? {
        guard isRegistered else { return nil }
        return collectWatchedAddresses().count
    }

    // MARK: - Private State

    private let tokenDefaultsKey = "push_device_token"
    private let registeredDefaultsKey = "push_registered"
    private let deviceAuthCounterDefaultsKey = "push_device_auth_counter"

    private var deviceToken: String?
    private var pendingRegistration = false
    private var registrationInFlight = false
    private var lastDeviceTokenHandledAt: Date?
    private var registrationContinuation: CheckedContinuation<Void, Error>?
    private var registrationTimeoutTask: Task<Void, Never>?
    private var recentlyHandledPushes: [String: Date] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var updateWatchedInFlight = false
    private var updateWatchedPending = false
    private var updateWatchedTask: Task<Void, Never>?
    private var lastWatchedUpdateAt: Date?
    private var lastWatchedUpdateSuccessAt: Date?
    private var lastWatchedSignature: String?
    private var pendingWatchedSignature: String?
    private var inFlightWatchedSignature: String?
    private var walletBindingConflictFingerprint: String?
    private var walletBindingConflictUntil: Date?
    private var lastWalletBindingConflictLogAt: Date?
    private let updateWatchedDebounce: TimeInterval = 1.0
    private let updateWatchedSuccessCooldown: TimeInterval = 10.0
    private let walletBindingConflictCooldown: TimeInterval = 15 * 60
    private let walletBindingConflictLogCooldown: TimeInterval = 60
    private var settingsObserver: NSObjectProtocol?
    private var conversationsCancellable: AnyCancellable?
    private var declinedContactsCancellable: AnyCancellable?

    // MARK: - Constants

    private let registrationEndpoint = "/v1/push/register"
    private let updateEndpoint = "/v1/push/update"
    private let unregisterEndpoint = "/v1/push/unregister"
    private let challengeEndpoint = "/v1/push/challenge"
    private let pushAuthDomain = "kasia-push-auth:v1"
    private let pushDeviceAuthDomain = "kasia-push-device-auth:v1"
    private let pushDeviceAuthScheme = "device_key_v1"

    // MARK: - Initialization

    private init() {
        loadPersistedState()
        observeSettingsChanges()
        observeConversationVisibilityChanges()
        Task {
            await checkPermissionStatus()
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        conversationsCancellable?.cancel()
        declinedContactsCancellable?.cancel()
    }

    // MARK: - Public API

    /// Request notification permission and register with APNs
    func requestPermissionAndRegister() async throws {
        let center = UNUserNotificationCenter.current()

        // Request permission
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

        await MainActor.run {
            permissionStatus = granted ? .authorized : .denied
        }

        guard granted else {
            throw PushError.permissionDenied
        }

        // Register with APNs - this will trigger didRegisterForRemoteNotifications
        pendingRegistration = true
        UIApplication.shared.registerForRemoteNotifications()

        NSLog("[Push] Requested APNs registration")
    }

    /// Request permission, register with APNs, and wait for indexer registration.
    func requestPermissionAndRegisterAndWaitForIndexer() async throws {
        let center = UNUserNotificationCenter.current()

        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

        await MainActor.run {
            permissionStatus = granted ? .authorized : .denied
        }

        guard granted else {
            throw PushError.permissionDenied
        }

        guard registrationContinuation == nil else {
            throw PushError.registrationInProgress
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            registrationContinuation = continuation
            pendingRegistration = true

            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    self?.completeRegistration(with: PushError.registrationTimedOut)
                }
            }

            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshRegistrationIfNeeded() {
        let settings = AppSettings.load()
        guard settings.notificationMode == .remotePush else { return }
        guard permissionStatus == .authorized || permissionStatus == .provisional else { return }
        guard registrationContinuation == nil else { return }

        if deviceToken == nil {
            pendingRegistration = true
            UIApplication.shared.registerForRemoteNotifications()
            return
        }

        if shouldDeferRegistrationForWalletBindingConflict() {
            return
        }

        if isRegistered {
            Task {
                await updateWatchedAddresses()
            }
            return
        }

        let watchedAddresses = collectWatchedAddresses()
        guard !watchedAddresses.isEmpty else { return }

        Task {
            do {
                try await registerWithIndexer()
            } catch {
                lastError = error.localizedDescription
                NSLog("[Push] Refresh registration failed: %@", error.localizedDescription)
                if registrationContinuation != nil {
                    completeRegistration(with: error)
                }
            }
        }
    }

    /// Force re-registration with the indexer when push reliability appears degraded.
    func forceReregister(reason: String) async {
        let settings = AppSettings.load()
        guard settings.notificationMode == .remotePush else { return }
        guard permissionStatus == .authorized || permissionStatus == .provisional else {
            NSLog("[Push] Skipping forced re-registration - permission not granted")
            return
        }
        guard registrationContinuation == nil else {
            NSLog("[Push] Skipping forced re-registration - explicit registration flow in progress")
            return
        }

        if deviceToken == nil {
            pendingRegistration = true
            UIApplication.shared.registerForRemoteNotifications()
            NSLog("[Push] Forced re-registration requested (%@), refreshing APNs token", reason)
            return
        }

        if shouldDeferRegistrationForWalletBindingConflict() {
            return
        }

        do {
            try await registerWithIndexer()
            NSLog("[Push] Forced re-registration succeeded (%@)", reason)
        } catch {
            lastError = error.localizedDescription
            NSLog("[Push] Forced re-registration failed (%@): %@",
                  reason,
                  error.localizedDescription)
        }
    }

    /// Called from AppDelegate when APNs token received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let previousToken = self.deviceToken
        if token == self.deviceToken,
           let last = lastDeviceTokenHandledAt,
           Date().timeIntervalSince(last) < 5 {
            return
        }
        lastDeviceTokenHandledAt = Date()
        self.deviceToken = token
        if previousToken != token {
            clearWalletBindingConflictCooldown()
        }
        persistDeviceToken(token)

        NSLog("[Push] Received APNs token: %@...%@",
              String(token.prefix(8)), String(token.suffix(8)))

        // If we were waiting for registration, complete it
        if pendingRegistration {
            pendingRegistration = false
            if registrationInFlight {
                Task {
                    await self.waitForInFlightRegistrationIfNeeded()
                }
                return
            }
            Task {
                do {
                    try await registerWithIndexer()
                    await MainActor.run {
                        self.completeRegistration()
                    }
                } catch {
                    NSLog("[Push] Failed to register with indexer: %@", error.localizedDescription)
                    lastError = error.localizedDescription
                    await MainActor.run {
                        self.completeRegistration(with: error)
                    }
                }
            }
        }
    }

    /// Called from AppDelegate when APNs registration fails
    func didFailToRegisterForRemoteNotifications(error: Error) {
        NSLog("[Push] APNs registration failed: %@", error.localizedDescription)
        pendingRegistration = false
        lastError = error.localizedDescription
        completeRegistration(with: error)
    }

    /// Register device with indexer, including watched addresses
    func registerWithIndexer() async throws {
        guard let token = deviceToken else {
            throw PushError.noDeviceToken
        }
        guard !registrationInFlight else {
            return
        }
        registrationInFlight = true
        defer { registrationInFlight = false }

        let settings = AppSettings.load()
        let watchedAddresses = collectWatchedAddresses()
        let aliases = collectAliases(forWatchedAddresses: watchedAddresses)
        let primaryAddress = collectPrimaryAddress()

        guard !watchedAddresses.isEmpty else {
            throw PushError.noWatchedAddresses
        }

        for attempt in 0..<2 {
            let (statusCode, reason) = try await submitRegistrationRequest(
                settings: settings,
                token: token,
                watchedAddresses: watchedAddresses,
                aliases: aliases,
                primaryAddress: primaryAddress
            )
            if statusCode == 200 {
                applySuccessfulRegistration(
                    watchedAddresses: watchedAddresses,
                    aliases: aliases,
                    primaryAddress: primaryAddress
                )
                return
            }
            if isWalletBindingConflict(statusCode: statusCode, reason: reason), attempt == 0 {
                let recovered = await attemptWalletBindingRecoveryUnregister(
                    token: token,
                    watchedAddresses: watchedAddresses,
                    aliases: aliases
                )
                if recovered {
                    continue
                }
            }
            if isWalletBindingConflict(statusCode: statusCode, reason: reason) {
                activateWalletBindingConflictCooldown(reason: reason)
            }
            throw PushError.registrationFailed(statusCode: statusCode, reason: reason)
        }
    }

    private func submitRegistrationRequest(
        settings: AppSettings,
        token: String,
        watchedAddresses: [String],
        aliases: [String],
        primaryAddress: String?
    ) async throws -> (Int, String?) {
        let url = URL(string: "\(settings.pushIndexerURL)\(registrationEndpoint)")!
        let auth = try await buildPushAuth(
            method: "POST",
            path: registrationEndpoint,
            deviceToken: token,
            watchedAddresses: watchedAddresses,
            primaryAddress: primaryAddress,
            aliases: aliases
        )

        #if targetEnvironment(macCatalyst)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif

        let request = PushRegistrationRequest(
            deviceToken: token,
            platform: platform,
            watchedAddresses: watchedAddresses,
            primaryAddress: primaryAddress,
            aliases: aliases,
            auth: auth
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 30

        let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushError.invalidResponse
        }
        let reason = parseIndexerError(from: responseData)
        return (httpResponse.statusCode, reason)
    }

    private func applySuccessfulRegistration(
        watchedAddresses: [String],
        aliases: [String],
        primaryAddress: String?
    ) {
        isRegistered = true
        lastError = nil
        persistRegistrationStatus(true)
        clearWalletBindingConflictCooldown()
        lastWatchedSignature = buildWatchedSignature(
            watchedAddresses: watchedAddresses,
            aliases: aliases,
            primaryAddress: primaryAddress
        )
        lastWatchedUpdateSuccessAt = Date()
        pendingWatchedSignature = nil
        inFlightWatchedSignature = nil

        SharedDataManager.syncContactsForExtension()

        NSLog("[Push] Registered with indexer, watching %d addresses", watchedAddresses.count)
        if registrationContinuation != nil {
            completeRegistration()
        }
    }

    private func attemptWalletBindingRecoveryUnregister(
        token: String,
        watchedAddresses: [String],
        aliases: [String]
    ) async -> Bool {
        let settings = AppSettings.load()
        guard let url = URL(string: "\(settings.pushIndexerURL)\(unregisterEndpoint)") else {
            return false
        }

        let auth: PushAuthRequest?
        do {
            auth = try await buildPushAuth(
                method: "DELETE",
                path: unregisterEndpoint,
                deviceToken: token,
                watchedAddresses: watchedAddresses,
                primaryAddress: nil,
                aliases: aliases
            )
        } catch {
            NSLog("[Push] Recovery unregister auth build failed: %@", error.localizedDescription)
            return false
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(
            PushUnregisterRequest(deviceToken: token, auth: auth)
        )
        urlRequest.timeoutInterval = 30

        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            if httpResponse.statusCode == 200 {
                isRegistered = false
                persistRegistrationStatus(false)
                NSLog("[Push] Recovery unregister succeeded, retrying register")
                return true
            }
            let reason = parseIndexerError(from: responseData) ?? "unknown"
            NSLog("[Push] Recovery unregister failed: status=%d reason=%@", httpResponse.statusCode, reason)
            return false
        } catch {
            NSLog("[Push] Recovery unregister error: %@", error.localizedDescription)
            return false
        }
    }

    private func waitForInFlightRegistrationIfNeeded() async {
        // Another registration attempt is already in-flight. Wait for it to settle so the
        // explicit "register and wait" path doesn't falsely time out.
        for _ in 0..<120 {
            if !registrationInFlight {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard registrationContinuation != nil else { return }
        if registrationInFlight {
            return
        }
        if isRegistered {
            completeRegistration()
            return
        }
        if let lastError {
            completeRegistration(with: PushError.authFailed(reason: lastError))
        }
    }

    private func completeRegistration(with error: Error? = nil) {
        pendingRegistration = false
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil

        guard let continuation = registrationContinuation else { return }
        registrationContinuation = nil

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Update watched addresses (call when contacts change)
    func updateWatchedAddresses() async {
        guard deviceToken != nil else { return }

        if !isRegistered {
            let watchedAddresses = collectWatchedAddresses()
            guard !watchedAddresses.isEmpty else { return }
            if shouldDeferRegistrationForWalletBindingConflict() {
                return
            }
            do {
                try await registerWithIndexer()
            } catch {
                lastError = error.localizedDescription
                NSLog("[Push] Failed to register with indexer while updating watched addresses: %@",
                      error.localizedDescription)
                if registrationContinuation != nil {
                    completeRegistration(with: error)
                }
            }
            return
        }

        if updateWatchedInFlight || updateWatchedTask != nil {
            updateWatchedPending = true
            pendingWatchedSignature = buildWatchedSignature()
            return
        }

        let now = Date()
        if let last = lastWatchedUpdateAt,
           now.timeIntervalSince(last) < updateWatchedDebounce {
            updateWatchedPending = true
            pendingWatchedSignature = buildWatchedSignature()
            if updateWatchedTask == nil {
                let delay = updateWatchedDebounce - now.timeIntervalSince(last)
                updateWatchedTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self?.runWatchedUpdate()
                }
            }
            return
        }
        let signature = buildWatchedSignature()
        if let lastSig = lastWatchedSignature,
           signature == lastSig,
           let lastSuccess = lastWatchedUpdateSuccessAt,
           now.timeIntervalSince(lastSuccess) < updateWatchedSuccessCooldown {
            return
        }

        lastWatchedUpdateAt = now
        pendingWatchedSignature = signature
        await runWatchedUpdate()
    }

    private func runWatchedUpdate() async {
        guard let token = deviceToken, isRegistered else {
            updateWatchedPending = false
            return
        }
        updateWatchedTask?.cancel()
        updateWatchedTask = nil
        if updateWatchedInFlight {
            updateWatchedPending = true
            return
        }
        updateWatchedInFlight = true
        defer {
            updateWatchedInFlight = false
        }

        let settings = AppSettings.load()
        let watchedAddresses = collectWatchedAddresses()
        let aliases = collectAliases(forWatchedAddresses: watchedAddresses)
        let primaryAddress = collectPrimaryAddress()
        if watchedAddresses.isEmpty {
            NSLog("[Push] No eligible chats for push, unregistering device from indexer")
            await unregister()
            lastWatchedSignature = ""
            lastWatchedUpdateSuccessAt = Date()
            pendingWatchedSignature = nil
            inFlightWatchedSignature = nil
            updateWatchedPending = false
            return
        }
        let signature = buildWatchedSignature(watchedAddresses: watchedAddresses, aliases: aliases, primaryAddress: primaryAddress)
        inFlightWatchedSignature = signature

        let auth: PushAuthRequest
        do {
            auth = try await buildPushAuth(
                method: "PUT",
                path: updateEndpoint,
                deviceToken: token,
                watchedAddresses: watchedAddresses,
                primaryAddress: primaryAddress,
                aliases: aliases
            )
        } catch {
            lastError = error.localizedDescription
            NSLog("[Push] Failed to build auth for watched update: %@", error.localizedDescription)
            return
        }

        let request = PushUpdateRequest(
            deviceToken: token,
            watchedAddresses: watchedAddresses,
            primaryAddress: primaryAddress,
            aliases: aliases,
            auth: auth
        )

        let url = URL(string: "\(settings.pushIndexerURL)\(updateEndpoint)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 30

        do {
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[Push] Failed to update watched addresses: invalid response")
                return
            }
            guard httpResponse.statusCode == 200 else {
                let reason = parseIndexerError(from: responseData) ?? "unknown"
                if isWalletBindingConflict(statusCode: httpResponse.statusCode, reason: reason) {
                    let recovered = await attemptWalletBindingRecoveryUnregister(
                        token: token,
                        watchedAddresses: watchedAddresses,
                        aliases: aliases
                    )
                    if recovered {
                        do {
                            try await registerWithIndexer()
                        } catch {
                            lastError = error.localizedDescription
                        }
                        return
                    }
                    activateWalletBindingConflictCooldown(reason: reason)
                    return
                }
                NSLog("[Push] Failed to update watched addresses: status=%d reason=%@", httpResponse.statusCode, reason)
                return
            }

            // Sync contacts to shared container
            SharedDataManager.syncContactsForExtension()

            lastWatchedSignature = signature
            lastWatchedUpdateSuccessAt = Date()
            NSLog("[Push] Updated watched addresses: %d", watchedAddresses.count)
        } catch {
            NSLog("[Push] Error updating addresses: %@", error.localizedDescription)
        }

        if updateWatchedPending {
            updateWatchedPending = false
            lastWatchedUpdateAt = Date()
            let nextSignature = pendingWatchedSignature
            pendingWatchedSignature = nil
            if let nextSignature,
               nextSignature != lastWatchedSignature,
               nextSignature != inFlightWatchedSignature {
                await runWatchedUpdate()
            }
        }
    }

    private func buildWatchedSignature(
        watchedAddresses: [String]? = nil,
        aliases: [String]? = nil,
        primaryAddress: String? = nil
    ) -> String {
        let addrs = (watchedAddresses ?? collectWatchedAddresses()).sorted()
        let aliasList = (aliases ?? collectAliases(forWatchedAddresses: addrs)).sorted()
        let primary = primaryAddress ?? collectPrimaryAddress() ?? ""
        return (addrs + ["|"] + aliasList + ["|", primary]).joined(separator: ",")
    }

    /// Unregister device (call on logout/wallet delete)
    func unregister() async {
        guard let token = deviceToken else { return }

        let settings = AppSettings.load()

        do {
            let url = URL(string: "\(settings.pushIndexerURL)\(unregisterEndpoint)")!
            let auth: PushAuthRequest?
            do {
                auth = try await buildPushAuth(
                    method: "DELETE",
                    path: unregisterEndpoint,
                    deviceToken: token,
                    watchedAddresses: [],
                    primaryAddress: nil,
                    aliases: []
                )
            } catch {
                // Best-effort fallback for mixed/legacy backend mode.
                NSLog("[Push] Failed to build auth for unregister, trying unsigned request: %@", error.localizedDescription)
                auth = nil
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "DELETE"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(
                PushUnregisterRequest(deviceToken: token, auth: auth)
            )
            urlRequest.timeoutInterval = 30

            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[Push] Error unregistering: invalid response")
                return
            }
            if httpResponse.statusCode == 200 {
                isRegistered = false
                persistRegistrationStatus(false)
                lastError = nil
                clearWalletBindingConflictCooldown()
                NSLog("[Push] Unregistered from indexer")
                return
            }

            let reason = parseIndexerError(from: responseData) ?? "unknown"
            if isWalletBindingConflict(statusCode: httpResponse.statusCode, reason: reason) {
                activateWalletBindingConflictCooldown(reason: reason)
            }
            if (400...499).contains(httpResponse.statusCode) {
                // Local token/state is stale or invalid for this backend; stop retry loops.
                isRegistered = false
                persistRegistrationStatus(false)
            }
            NSLog("[Push] Failed to unregister: status=%d reason=%@", httpResponse.statusCode, reason)
        } catch {
            NSLog("[Push] Error unregistering: %@", error.localizedDescription)
        }
    }

    /// Process pending messages stored by notification extension
    func processPendingMessages() async {
        // Get messages decrypted by extension
        let storedMessages = SharedDataManager.getStoredMessages()
        if !storedMessages.isEmpty {
            NSLog("[Push] Processing %d messages from extension", storedMessages.count)

            for msg in storedMessages {
                // Add to ChatService if not already present
                if let txId = msg["txId"] as? String,
                   let sender = msg["sender"] as? String,
                   let content = msg["content"] as? String,
                   let timestamp = msg["timestamp"] as? Int64 {
                    ChatService.shared.recordRemotePushDelivery(
                        txId: txId,
                        sender: sender,
                        messageType: "contextual"
                    )
                    await ChatService.shared.addMessageFromPush(
                        txId: txId,
                        sender: sender,
                        content: content,
                        timestamp: timestamp
                    )
                }
            }

            SharedDataManager.clearStoredMessages()
        }

        // Get pending messages that need fetching (large payloads)
        let pendingMessages = SharedDataManager.getPendingMessages()
        if !pendingMessages.isEmpty {
            NSLog("[Push] Fetching %d pending messages", pendingMessages.count)

            var failed: [SharedPendingMessage] = []
            for pending in pendingMessages {
                ChatService.shared.recordRemotePushDelivery(
                    txId: pending.txId,
                    sender: pending.sender,
                    messageType: pending.type
                )
                let fetched: Bool
                if pending.type == "payment" {
                    fetched = await ChatService.shared.fetchPaymentByTxId(
                        pending.txId,
                        sender: pending.sender,
                        amount: nil,
                        timestamp: pending.timestamp
                    )
                } else {
                    fetched = await ChatService.shared.fetchMessageByTxId(pending.txId, sender: pending.sender)
                }
                if !fetched {
                    failed.append(pending)
                }
            }

            SharedDataManager.setPendingMessages(failed)
        }
    }

    /// Handle an incoming remote push payload and update chats immediately.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        let settings = AppSettings.load()
        guard settings.notificationMode == .remotePush else { return false }

        guard let txId = userInfo["tx_id"] as? String,
              let sender = userInfo["sender"] as? String,
              let messageType = userInfo["type"] as? String else {
            return false
        }

        ChatService.shared.recordRemotePushDelivery(
            txId: txId,
            sender: sender,
            messageType: messageType
        )

        pruneRecentlyHandledPushes()
        if let lastHandled = recentlyHandledPushes[txId], Date().timeIntervalSince(lastHandled) < 60 {
            NSLog("[Push] Remote push already handled recently: %@", txId)
            return true
        }

        let timestamp = extractTimestamp(userInfo: userInfo)
        let payload = userInfo["payload"] as? String
        let amount = extractAmount(userInfo: userInfo)

        if messageType == "payment" {
            if let ourAddress = WalletManager.shared.currentWallet?.publicAddress,
               sender == ourAddress,
               ChatService.shared.hasLocalMessage(txId: txId) {
                NSLog("[Push] Outgoing payment already in local messages: %@", txId)
                return true
            }

            if await ChatService.shared.addPaymentFromPush(
                txId: txId,
                sender: sender,
                amount: amount,
                payload: payload,
                timestamp: timestamp
            ) {
                NSLog("[Push] Remote payment handled: %@", txId)
                recentlyHandledPushes[txId] = Date()
                if let task = retryTasks.removeValue(forKey: txId) {
                    task.cancel()
                }
                SharedDataManager.removePendingMessage(txId: txId)
                return true
            }

            NSLog("[Push] Remote payment handled via fetch: %@", txId)
            let fetched = await ChatService.shared.fetchPaymentByTxId(
                txId,
                sender: sender,
                amount: amount,
                timestamp: timestamp
            )
            if !fetched {
                SharedDataManager.addPendingMessage(txId: txId, sender: sender, type: messageType)
                NSLog("[Push] Remote payment fetch failed, queued for retry: %@", txId)
                scheduleRetryFetchIfActive(txId: txId, sender: sender, type: messageType)
                return false
            }
            recentlyHandledPushes[txId] = Date()
            if let task = retryTasks.removeValue(forKey: txId) {
                task.cancel()
            }
            SharedDataManager.removePendingMessage(txId: txId)
            return true
        }

        if let ourAddress = WalletManager.shared.currentWallet?.publicAddress,
           sender == ourAddress {
            if ChatService.shared.hasLocalMessage(txId: txId) {
                NSLog("[Push] Outgoing push already in local messages: %@", txId)
                return true
            }
            return await ChatService.shared.addOutgoingMessageFromPush(
                txId: txId,
                sender: sender,
                payload: payload,
                timestamp: timestamp
            )
        }

        if messageType == "contextual" {
            if let payload {
                NSLog("[Push] Remote push payload len=%d tx=%@", payload.count, txId)
                if let content = decryptContextualPayload(payload) {
                    NSLog("[Push] Remote push handled via decrypt: %@", txId)
                    recentlyHandledPushes[txId] = Date()
                    if let task = retryTasks.removeValue(forKey: txId) {
                        task.cancel()
                    }
                    SharedDataManager.removePendingMessage(txId: txId)
                    await ChatService.shared.addMessageFromPush(
                        txId: txId,
                        sender: sender,
                        content: content,
                        timestamp: timestamp
                    )
                    return true
                }
            } else {
                NSLog("[Push] Remote push missing payload: %@", txId)
            }
        }

        NSLog("[Push] Remote push handled via fetch: %@", txId)
        let fetched = await ChatService.shared.fetchMessageByTxId(txId, sender: sender)
        if !fetched {
            SharedDataManager.addPendingMessage(txId: txId, sender: sender, type: messageType)
            NSLog("[Push] Remote push fetch failed, queued for retry: %@", txId)
            scheduleRetryFetchIfActive(txId: txId, sender: sender, type: messageType)
            return false
        }
        recentlyHandledPushes[txId] = Date()
        if let task = retryTasks.removeValue(forKey: txId) {
            task.cancel()
        }
        SharedDataManager.removePendingMessage(txId: txId)
        return true
    }

    // MARK: - Private Helpers

    private func loadPersistedState() {
        // Try Keychain first, then migrate from UserDefaults if needed
        if let keychainToken = loadTokenFromKeychain() {
            deviceToken = keychainToken
        } else {
            // Migration: check UserDefaults for legacy token
            let defaults = UserDefaults.standard
            if let legacyToken = defaults.string(forKey: tokenDefaultsKey) {
                deviceToken = legacyToken
                saveTokenToKeychain(legacyToken)
                defaults.removeObject(forKey: tokenDefaultsKey)
            }
        }
        let storedRegistered = UserDefaults.standard.bool(forKey: registeredDefaultsKey)
        isRegistered = storedRegistered && deviceToken != nil
    }

    private func persistDeviceToken(_ token: String) {
        saveTokenToKeychain(token)
    }

    // MARK: - Keychain Helpers (Push Token)

    private static let keychainService = "com.kachat.app"
    private static let keychainAccount = "push_device_token"
    private static let deviceAuthKeychainAccount = "push_device_auth_private_key"

    private func saveTokenToKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func saveDeviceAuthPrivateKeyToKeychain(_ keyData: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.deviceAuthKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadDeviceAuthPrivateKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.deviceAuthKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func nextDeviceAuthCounter() -> UInt64 {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: deviceAuthCounterDefaultsKey) as? NSNumber
        let next = previous?.uint64Value ?? 0
        let advanced = next &+ 1
        defaults.set(NSNumber(value: advanced), forKey: deviceAuthCounterDefaultsKey)
        return advanced
    }

    private func persistRegistrationStatus(_ isRegistered: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(isRegistered, forKey: registeredDefaultsKey)
    }

    private func checkPermissionStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        permissionStatus = settings.authorizationStatus
        refreshRegistrationIfNeeded()
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRegistrationIfNeeded()
            }
        }
    }

    private func observeConversationVisibilityChanges() {
        conversationsCancellable = ChatService.shared.$conversations
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = AppSettings.load()
                guard settings.notificationMode == .remotePush else { return }
                Task { await self.updateWatchedAddresses() }
            }

        declinedContactsCancellable = ChatService.shared.$declinedContacts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = AppSettings.load()
                guard settings.notificationMode == .remotePush else { return }
                Task { await self.updateWatchedAddresses() }
            }
    }

    private func collectWatchedAddresses() -> [String] {
        let settings = AppSettings.load()
        return ChatService.shared.pushEligibleConversationAddresses(settings: settings)
    }

    private func collectAliases(forWatchedAddresses watchedAddresses: [String]? = nil) -> [String] {
        let addresses = Set((watchedAddresses ?? collectWatchedAddresses()).map { $0.lowercased() })
        let aliases = ChatService.shared.knownIncomingAliases(forAddresses: addresses)
        let normalized = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(normalized))
    }

    private func collectPrimaryAddress() -> String? {
        WalletManager.shared.currentWallet?.publicAddress
    }

    private func buildPushAuth(
        method: String,
        path: String,
        deviceToken: String,
        watchedAddresses: [String],
        primaryAddress: String?,
        aliases: [String]
    ) async throws -> PushAuthRequest {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw PushError.authFailed(reason: "No active wallet")
        }

        guard let privateKey = try KeychainService.shared.loadPrivateKey() else {
            throw PushError.authFailed(reason: "Wallet private key is missing")
        }

        let settings = AppSettings.load()
        let challenge = try await fetchPushChallenge(baseURL: settings.pushIndexerURL)

        let walletPubkey = wallet.publicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard walletPubkey.count == 64, isHexString(walletPubkey) else {
            throw PushError.authFailed(reason: "Wallet public key must be 32-byte hex")
        }

        guard let walletAddress = canonicalAddressForAuth(wallet.publicAddress, network: settings.networkType) else {
            throw PushError.authFailed(reason: "Wallet address is invalid")
        }

        let normalizedDeviceToken = try normalizeDeviceTokenForAuth(deviceToken)
        let normalizedPrimaryAddress = canonicalAddressForAuth(primaryAddress, network: settings.networkType) ?? ""
        let localTimestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let timestampMs = min(
            max(localTimestampMs, challenge.issuedAtMs),
            challenge.expiresAtMs
        )

        let preimage = buildAuthPreimage(
            nonce: challenge.nonce,
            method: method,
            path: path,
            deviceToken: normalizedDeviceToken,
            watchedAddresses: watchedAddresses,
            primaryAddress: normalizedPrimaryAddress,
            aliases: aliases,
            walletPubkey: walletPubkey,
            walletAddress: walletAddress,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs
        )

        var signingMaterial = privateKey
        defer { signingMaterial.zeroOut() }
        let signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: signingMaterial)

        let digest = Data(CryptoKit.SHA256.hash(data: Data(preimage.utf8)))
        var message = [UInt8](digest)
        defer {
            for index in message.indices {
                message[index] = 0
            }
        }
        let signature = try signingKey.signature(message: &message, auxiliaryRand: nil)
        let deviceAuth = try buildDeviceAuthProof(
            nonce: challenge.nonce,
            method: method,
            path: path,
            normalizedDeviceToken: normalizedDeviceToken,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs
        )
        let deviceCheckToken = await generateDeviceCheckToken()

        return PushAuthRequest(
            walletPubkey: walletPubkey,
            walletAddress: walletAddress,
            nonce: challenge.nonce,
            timestampMs: timestampMs,
            expiresAtMs: challenge.expiresAtMs,
            signature: Data(signature.bytes).hexString,
            devicecheckToken: deviceCheckToken,
            deviceAuth: PushDeviceAuthRequest(
                scheme: deviceAuth.scheme,
                keyId: deviceAuth.keyId,
                pubkey: deviceAuth.pubkey,
                counter: deviceAuth.counter,
                signature: deviceAuth.signature
            )
        )
    }

    private func fetchPushChallenge(baseURL: String) async throws -> PushChallengeResponse {
        let url = URL(string: "\(baseURL)\(challengeEndpoint)")!
        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15

            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PushError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let reason = parseIndexerError(from: responseData) ?? "unknown"
                    throw PushError.authFailed(
                        reason: "Challenge failed (status: \(httpResponse.statusCode)): \(reason)"
                    )
                }

                do {
                    return try JSONDecoder().decode(PushChallengeResponse.self, from: responseData)
                } catch {
                    throw PushError.authFailed(reason: "Invalid challenge response")
                }
            } catch let urlError as URLError where isTransientChallengeNetworkError(urlError) && attempt < 2 {
                let delayNs = UInt64((attempt + 1) * 300_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                continue
            }
        }
        throw PushError.authFailed(reason: "Failed to fetch challenge")
    }

    private func isTransientChallengeNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func buildAuthPreimage(
        nonce: String,
        method: String,
        path: String,
        deviceToken: String,
        watchedAddresses: [String],
        primaryAddress: String,
        aliases: [String],
        walletPubkey: String,
        walletAddress: String,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) -> String {
        let watchedHash = sha256Hex(canonicalizeWatchedAddressesForAuth(watchedAddresses).joined(separator: "\n"))
        let aliasesHash = sha256Hex(canonicalizeAliasesForAuth(aliases).joined(separator: "\n"))
        let deviceTokenHash = sha256Hex(deviceToken)

        return [
            "domain=\(pushAuthDomain)",
            "nonce=\(nonce.trimmingCharacters(in: .whitespacesAndNewlines))",
            "method=\(method)",
            "path=\(path)",
            "device_token_hash=\(deviceTokenHash)",
            "watched_addresses_hash=\(watchedHash)",
            "primary_address=\(primaryAddress)",
            "aliases_hash=\(aliasesHash)",
            "wallet_pubkey=\(walletPubkey)",
            "wallet_address=\(walletAddress)",
            "timestamp_ms=\(timestampMs)",
            "expires_at_ms=\(expiresAtMs)"
        ].joined(separator: "\n")
    }

    private struct DeviceKeyMaterial {
        let privateKey: P256.Signing.PrivateKey
        let publicKeyData: Data
        let keyId: String
    }

    private struct DeviceAuthProof {
        let scheme: String
        let keyId: String
        let pubkey: String
        let counter: UInt64
        let signature: String
    }

    private func loadOrCreateDeviceKeyMaterial() throws -> DeviceKeyMaterial {
        if let keyData = loadDeviceAuthPrivateKeyFromKeychain(),
           let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            let publicKeyData = privateKey.publicKey.x963Representation
            let keyId = Data(CryptoKit.SHA256.hash(data: publicKeyData)).hexString
            return DeviceKeyMaterial(privateKey: privateKey, publicKeyData: publicKeyData, keyId: keyId)
        }

        let privateKey = P256.Signing.PrivateKey()
        let keyData = privateKey.rawRepresentation
        saveDeviceAuthPrivateKeyToKeychain(keyData)
        let publicKeyData = privateKey.publicKey.x963Representation
        let keyId = Data(CryptoKit.SHA256.hash(data: publicKeyData)).hexString
        return DeviceKeyMaterial(privateKey: privateKey, publicKeyData: publicKeyData, keyId: keyId)
    }

    private func buildDeviceAuthPreimage(
        nonce: String,
        method: String,
        path: String,
        deviceToken: String,
        keyId: String,
        counter: UInt64,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) -> String {
        let deviceTokenHash = sha256Hex(deviceToken)
        return [
            "domain=\(pushDeviceAuthDomain)",
            "nonce=\(nonce.trimmingCharacters(in: .whitespacesAndNewlines))",
            "method=\(method)",
            "path=\(path)",
            "device_token_hash=\(deviceTokenHash)",
            "key_id=\(keyId)",
            "counter=\(counter)",
            "timestamp_ms=\(timestampMs)",
            "expires_at_ms=\(expiresAtMs)"
        ].joined(separator: "\n")
    }

    private func buildDeviceAuthProof(
        nonce: String,
        method: String,
        path: String,
        normalizedDeviceToken: String,
        timestampMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> DeviceAuthProof {
        let material = try loadOrCreateDeviceKeyMaterial()
        let counter = nextDeviceAuthCounter()
        let preimage = buildDeviceAuthPreimage(
            nonce: nonce,
            method: method,
            path: path,
            deviceToken: normalizedDeviceToken,
            keyId: material.keyId,
            counter: counter,
            timestampMs: timestampMs,
            expiresAtMs: expiresAtMs
        )
        let signature = try material.privateKey.signature(for: Data(preimage.utf8))
        return DeviceAuthProof(
            scheme: pushDeviceAuthScheme,
            keyId: material.keyId,
            pubkey: material.publicKeyData.base64EncodedString(),
            counter: counter,
            signature: signature.derRepresentation.base64EncodedString()
        )
    }

    private func generateDeviceCheckToken() async -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard DCDevice.current.isSupported else {
            return nil
        }
        do {
            return try await DCDevice.current.generateToken().base64EncodedString()
        } catch {
            return nil
        }
        #endif
    }

    private func normalizeDeviceTokenForAuth(_ token: String) throws -> String {
        let cleaned = token.filter { $0.isHexDigit }.lowercased()
        if cleaned.count < 64 || cleaned.count > 512 || cleaned.count % 2 != 0 {
            throw PushError.authFailed(reason: "Invalid device token length")
        }
        return cleaned
    }

    private func canonicalizeWatchedAddressesForAuth(_ addresses: [String]) -> [String] {
        var set = Set<String>()
        for address in addresses {
            let normalized = address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalized.isEmpty {
                set.insert(normalized)
            }
        }
        return set.sorted()
    }

    private func canonicalizeAliasesForAuth(_ aliases: [String]) -> [String] {
        var set = Set<String>()
        for alias in aliases {
            let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                set.insert(normalized)
            }
        }
        return set.sorted()
    }

    private func canonicalAddressForAuth(_ address: String?, network: NetworkType) -> String? {
        guard var normalized = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }

        if !normalized.contains(":") {
            let prefix = network == .mainnet ? "kaspa" : "kaspatest"
            normalized = "\(prefix):\(normalized)"
        }

        normalized = normalized.lowercased()
        guard let parsed = KaspaAddress(address: normalized) else {
            return nil
        }
        return parsed.address
    }

    private func sha256Hex(_ value: String) -> String {
        Data(CryptoKit.SHA256.hash(data: Data(value.utf8))).hexString
    }

    private func isHexString(_ value: String) -> Bool {
        let charset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { charset.contains($0) }
    }

    private func isWalletBindingConflict(statusCode: Int, reason: String?) -> Bool {
        guard statusCode == 401, let reason else { return false }
        return reason.lowercased().contains("bound to another wallet")
    }

    private func currentWalletBindingFingerprint() -> String? {
        guard let token = deviceToken else { return nil }
        guard let walletPubkey = WalletManager.shared.currentWallet?.publicKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !walletPubkey.isEmpty else {
            return nil
        }
        return "\(token)|\(walletPubkey)"
    }

    private func shouldDeferRegistrationForWalletBindingConflict() -> Bool {
        guard let blockedFingerprint = walletBindingConflictFingerprint,
              let blockedUntil = walletBindingConflictUntil else {
            return false
        }
        guard let currentFingerprint = currentWalletBindingFingerprint(),
              currentFingerprint == blockedFingerprint else {
            clearWalletBindingConflictCooldown()
            return false
        }
        let now = Date()
        if now >= blockedUntil {
            clearWalletBindingConflictCooldown()
            return false
        }
        if let lastLog = lastWalletBindingConflictLogAt,
           now.timeIntervalSince(lastLog) < walletBindingConflictLogCooldown {
            return true
        }
        let remainingSeconds = Int(ceil(blockedUntil.timeIntervalSince(now)))
        NSLog("[Push] Skipping push registration for %ds due to wallet binding conflict", max(1, remainingSeconds))
        lastWalletBindingConflictLogAt = now
        return true
    }

    private func activateWalletBindingConflictCooldown(reason: String?) {
        guard let fingerprint = currentWalletBindingFingerprint() else { return }
        walletBindingConflictFingerprint = fingerprint
        walletBindingConflictUntil = Date().addingTimeInterval(walletBindingConflictCooldown)
        isRegistered = false
        persistRegistrationStatus(false)

        let now = Date()
        if let lastLog = lastWalletBindingConflictLogAt,
           now.timeIntervalSince(lastLog) < walletBindingConflictLogCooldown {
            return
        }
        lastWalletBindingConflictLogAt = now
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedReason, !normalizedReason.isEmpty {
            NSLog("[Push] Token-wallet binding conflict: %@. Deferring retries for %.0f seconds.",
                  normalizedReason,
                  walletBindingConflictCooldown)
        } else {
            NSLog("[Push] Token-wallet binding conflict. Deferring retries for %.0f seconds.",
                  walletBindingConflictCooldown)
        }
    }

    private func clearWalletBindingConflictCooldown() {
        walletBindingConflictFingerprint = nil
        walletBindingConflictUntil = nil
        lastWalletBindingConflictLogAt = nil
    }

    private func parseIndexerError(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(PushIndexerErrorResponse.self, from: data) {
            let message = decoded.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
        if let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private func decryptContextualPayload(_ payload: String) -> String? {
        guard let privateKey = try? KeychainService.shared.loadPrivateKey() else {
            NSLog("[Push] Decrypt failed: missing private key")
            return nil
        }

        if let payloadString = decodePayloadString(from: payload),
           payloadString.hasPrefix("ciph_msg:1:comm:") {
            let parts = payloadString.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return nil }
            let base64String = String(parts[4])
            guard let encryptedData = Data(base64Encoded: base64String) else { return nil }
            return decryptEncryptedBytes(encryptedData, privateKey: privateKey)
        }

        if let encryptedData = Data(base64Encoded: payload) {
            if let decrypted = decryptEncryptedBytes(encryptedData, privateKey: privateKey) {
                return decrypted
            }

            if let utf8 = String(data: encryptedData, encoding: .utf8) {
                if let hexData = Data(hexString: utf8) {
                    return decryptEncryptedBytes(hexData, privateKey: privateKey)
                }
                if let payloadString = decodePayloadString(from: utf8),
                   payloadString.hasPrefix("ciph_msg:1:comm:") {
                    let parts = payloadString.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
                    if parts.count >= 5,
                       let nestedEncrypted = Data(base64Encoded: String(parts[4])) {
                        return decryptEncryptedBytes(nestedEncrypted, privateKey: privateKey)
                    }
                }
            }
        }

        if let encryptedData = Data(hexString: payload) {
            return decryptEncryptedBytes(encryptedData, privateKey: privateKey)
        }

        return nil
    }

    private func decodePayloadString(from payload: String) -> String? {
        if let payloadData = Data(hexString: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            return payloadString
        }
        if payload.hasPrefix("ciph_msg:") {
            return payload
        }
        return nil
    }

    private func decryptEncryptedBytes(_ encryptedData: Data, privateKey: Data) -> String? {
        guard let encrypted = KasiaCipher.EncryptedMessage(fromBytes: encryptedData) else {
            NSLog("[Push] Decrypt failed: invalid encrypted message len=%d", encryptedData.count)
            return nil
        }
        do {
            return try KasiaCipher.decrypt(encrypted, privateKey: privateKey)
        } catch {
            NSLog("[Push] Decrypt failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func extractTimestamp(userInfo: [AnyHashable: Any]) -> Int64 {
        if let timestamp = userInfo["timestamp"] as? Int64 {
            return timestamp
        }
        if let timestamp = userInfo["timestamp"] as? NSNumber {
            return timestamp.int64Value
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func extractAmount(userInfo: [AnyHashable: Any]) -> UInt64? {
        if let amount = userInfo["amount"] as? UInt64 {
            return amount
        }
        if let amount = userInfo["amount"] as? Int {
            return UInt64(amount)
        }
        if let amount = userInfo["amount"] as? NSNumber {
            return amount.uint64Value
        }
        if let amount = userInfo["amount"] as? String, let value = UInt64(amount) {
            return value
        }
        return nil
    }

    private func pruneRecentlyHandledPushes() {
        let cutoff = Date().addingTimeInterval(-120)
        recentlyHandledPushes = recentlyHandledPushes.filter { $0.value >= cutoff }
    }

    private func scheduleRetryFetchIfActive(txId: String, sender: String, type: String?) {
        guard UIApplication.shared.applicationState == .active else { return }
        if retryTasks[txId] != nil {
            return
        }

        retryTasks[txId] = Task { [weak self] in
            let delays: [UInt64] = [5, 15, 30]
            for seconds in delays {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                let fetched: Bool
                if type == "payment" {
                    fetched = await ChatService.shared.fetchPaymentByTxId(
                        txId,
                        sender: sender,
                        amount: nil,
                        timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                } else {
                    fetched = await ChatService.shared.fetchMessageByTxId(txId, sender: sender)
                }
                if fetched {
                    SharedDataManager.removePendingMessage(txId: txId)
                    await MainActor.run {
                        self?.recentlyHandledPushes[txId] = Date()
                    }
                    break
                }
            }
            await MainActor.run {
                self?.retryTasks[txId] = nil
            }
        }
    }
}

// MARK: - Request Models

struct PushRegistrationRequest: Codable {
    let deviceToken: String
    let platform: String
    let watchedAddresses: [String]
    let primaryAddress: String?
    let aliases: [String]
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case platform
        case watchedAddresses = "watched_addresses"
        case primaryAddress = "primary_address"
        case aliases
        case auth
    }
}

struct PushUpdateRequest: Codable {
    let deviceToken: String
    let watchedAddresses: [String]
    let primaryAddress: String?
    let aliases: [String]
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case watchedAddresses = "watched_addresses"
        case primaryAddress = "primary_address"
        case aliases
        case auth
    }
}

struct PushUnregisterRequest: Codable {
    let deviceToken: String
    let auth: PushAuthRequest?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case auth
    }
}

struct PushAuthRequest: Codable {
    let walletPubkey: String
    let walletAddress: String
    let nonce: String
    let timestampMs: UInt64
    let expiresAtMs: UInt64
    let signature: String
    let devicecheckToken: String?
    let deviceAuth: PushDeviceAuthRequest?

    enum CodingKeys: String, CodingKey {
        case walletPubkey = "wallet_pubkey"
        case walletAddress = "wallet_address"
        case nonce
        case timestampMs = "timestamp_ms"
        case expiresAtMs = "expires_at_ms"
        case signature
        case devicecheckToken = "devicecheck_token"
        case deviceAuth = "device_auth"
    }
}

struct PushDeviceAuthRequest: Codable {
    let scheme: String
    let keyId: String
    let pubkey: String
    let counter: UInt64
    let signature: String

    enum CodingKeys: String, CodingKey {
        case scheme
        case keyId = "key_id"
        case pubkey
        case counter
        case signature
    }
}

private struct PushChallengeResponse: Decodable {
    let nonce: String
    let issuedAtMs: UInt64
    let expiresAtMs: UInt64

    enum CodingKeys: String, CodingKey {
        case nonce
        case issuedAtMs = "issued_at_ms"
        case expiresAtMs = "expires_at_ms"
    }
}

private struct PushIndexerErrorResponse: Decodable {
    let error: String
}

// MARK: - Errors

enum PushError: LocalizedError {
    case permissionDenied
    case noDeviceToken
    case invalidResponse
    case registrationFailed(statusCode: Int, reason: String?)
    case updateFailed
    case registrationTimedOut
    case registrationInProgress
    case noWatchedAddresses
    case authFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notification permission denied"
        case .noDeviceToken:
            return "No device token available. Please enable notifications."
        case .invalidResponse:
            return "Invalid response from server"
        case .registrationFailed(let statusCode, let reason):
            if let reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Registration failed (status: \(statusCode)): \(reason)"
            }
            return "Registration failed (status: \(statusCode))"
        case .updateFailed:
            return "Failed to update push registration"
        case .registrationTimedOut:
            return "Push registration timed out"
        case .registrationInProgress:
            return "Push registration already in progress"
        case .noWatchedAddresses:
            return "No addresses available for push notifications"
        case .authFailed(let reason):
            return "Push auth failed: \(reason)"
        }
    }
}
