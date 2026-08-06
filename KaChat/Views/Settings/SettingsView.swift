import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    // Deliberately NOT observing ChatService here: this screen only *calls* it in actions (via
    // ChatService.shared), it never reads its @Published state in the Form body. Observing it made
    // the whole Settings Form recompute on ChatService's high-frequency sync churn for the first
    // ~15s after login, which was the scroll jank. The connection-status views are separate and
    // keep their own observation.
    @Environment(\.dismiss) private var dismiss

    @State private var showSeedPhrase = false
    @State private var showDeleteConfirmation = false
    @State private var showWipeIncomingConfirmation = false
    @State private var showWipeAccountConfirmation = false
    @State private var showWipeAccountCloudConfirmation = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var messageStoreSize = "Unknown"
    @State private var cloudKitStorageSize: String = "Not checked"
    @State private var isRefreshingCloudKitStorage = false
    @State private var diagnosticsArchiveURL: URL?
    @State private var showDiagnosticsShareSheet = false
    @State private var chatHistoryArchiveURL: URL?
    @State private var showChatHistoryShareSheet = false
    @State private var showChatHistoryImporter = false
    @State private var isPreparingDiagnostics = false
    @State private var isPreparingChatHistoryExport = false
    @State private var isImportingChatHistory = false
    @State private var showPhotoQualitySheet = false
    @AppStorage(MessageStore.dpiCorruptionWarningKey) private var dpiWarningActive = false
    @AppStorage(MessageStore.dpiCorruptionWarningEndpointKey) private var dpiWarningEndpoint = ""
    @AppStorage(MessageStore.dpiCorruptionWarningDateKey) private var dpiWarningDate: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Customization") {
                    Picker("Appearance", selection: $settingsViewModel.settings.appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: settingsViewModel.settings.appearance) { _ in
                        settingsViewModel.saveSettings()
                    }

                    Picker("Language", selection: $settingsViewModel.settings.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: settingsViewModel.settings.language) { newValue in
                        settingsViewModel.saveSettings()
                        settingsViewModel.applyLanguagePreference(newValue)
                    }

                    Picker("Currency", selection: $settingsViewModel.settings.currency) {
                        ForEach(AppCurrency.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .onChange(of: settingsViewModel.settings.currency) { _ in
                        settingsViewModel.saveSettings()
                    }

                    NavigationLink {
                        MenuVisibilityView()
                    } label: {
                        Label("Menu", systemImage: "list.bullet")
                    }

                    Toggle("Show Setup Guides", isOn: Binding(
                        get: { walletManager.showSetupGuides },
                        set: { walletManager.showSetupGuides = $0 }
                    ))
                }

                Section("Security") {
                    Toggle("Biometrics for Seed Phrase", isOn: $settingsViewModel.settings.biometricSeedPhraseEnabled)
                        .onChange(of: settingsViewModel.settings.biometricSeedPhraseEnabled) { _ in
                            settingsViewModel.saveSettings()
                        }

                    Toggle("Biometrics for Account Login", isOn: $settingsViewModel.settings.biometricAccountLoginEnabled)
                        .onChange(of: settingsViewModel.settings.biometricAccountLoginEnabled) { _ in
                            settingsViewModel.saveSettings()
                        }

                    Toggle("Biometrics for Address Private Keys", isOn: $settingsViewModel.settings.biometricSpendingKeyEnabled)
                        .onChange(of: settingsViewModel.settings.biometricSpendingKeyEnabled) { _ in
                            settingsViewModel.saveSettings()
                        }
                }

                // Connection Section
                Section("Connection") {
                    NavigationLink {
                        ConnectionSettingsView()
                    } label: {
                        HStack {
                            Label("Connection Settings", systemImage: "network")
                            Spacer()
                            Text(settingsViewModel.settings.networkType.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink {
                        KaspaExplorerSettingsView()
                    } label: {
                        HStack {
                            Label("Kaspa Explorer", systemImage: "safari")
                            Spacer()
                            Text(settingsViewModel.settings.kaspaExplorer.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Chats") {
                    Toggle("Show Fee Estimate", isOn: $settingsViewModel.settings.showFeeEstimate)
                        .onChange(of: settingsViewModel.settings.showFeeEstimate) { _ in
                            settingsViewModel.saveSettings()
                        }

                    Toggle("Require approval for photos from new contacts", isOn: $settingsViewModel.settings.requirePhotoApprovalForNewContacts)
                        .onChange(of: settingsViewModel.settings.requirePhotoApprovalForNewContacts) { _ in
                            settingsViewModel.saveSettings()
                        }

                    NavigationLink {
                        NotificationsSettingsView()
                    } label: {
                        HStack {
                            Label("Notifications", systemImage: "bell.badge")
                            Spacer()
                            Text(settingsViewModel.settings.notificationMode.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        showPhotoQualitySheet = true
                    } label: {
                        HStack {
                            Label("Photo Quality", systemImage: "photo")
                            Spacer()
                            Text(settingsViewModel.settings.chatPhotoQualityPreset.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink {
                        QuickReactionEmojisSettingsView(settingsViewModel: settingsViewModel)
                    } label: {
                        HStack {
                            Label("Quick Reactions", systemImage: "face.smiling")
                            Spacer()
                            Text(settingsViewModel.settings.effectiveQuickReactionEmojis.joined())
                                .font(.caption)
                        }
                    }
                }

                Section("Contacts") {
                    Toggle("Sync system contacts", isOn: Binding(
                        get: { settingsViewModel.settings.syncSystemContacts },
                        set: { enabled in
                            handleSystemContactsSyncToggle(enabled)
                        }
                    ))

                    Toggle("Autocreate system contacts", isOn: Binding(
                        get: { settingsViewModel.settings.autoCreateSystemContacts },
                        set: { enabled in
                            handleAutoCreateSystemContactsToggle(enabled)
                        }
                    ))
                    .disabled(!settingsViewModel.settings.syncSystemContacts)

                    Text("Uses your device contacts to match and enrich Kaspa contacts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Storage") {
                    Toggle("Store encrypted messages in iCloud CloudKit", isOn: $settingsViewModel.settings.storeMessagesInICloud)
                        .onChange(of: settingsViewModel.settings.storeMessagesInICloud) { _ in
                            settingsViewModel.saveSettings()
                            refreshMessageStoreSize()
                        }

                    Text("Required for cross-device sync and backup of sent messages.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Message retention", selection: $settingsViewModel.settings.messageRetention) {
                        ForEach(MessageRetention.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: settingsViewModel.settings.messageRetention) { _ in
                        settingsViewModel.saveSettings()
                        refreshMessageStoreSize()
                    }

                    Text("Local storage used: \(messageStoreSize)")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud storage used: \(cloudKitStorageSize)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Text("This is a live check of your iCloud account, separate from local storage above.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isRefreshingCloudKitStorage {
                            ProgressView()
                        } else {
                            Button {
                                Task { await refreshCloudKitStorageSize() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }

                Section("Chat History") {
                    Button {
                        Task {
                            await exportChatHistoryArchive()
                        }
                    } label: {
                        HStack {
                            Label("Export Chat History", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isPreparingChatHistoryExport {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPreparingChatHistoryExport || isImportingChatHistory)

                    Button {
                        showChatHistoryImporter = true
                    } label: {
                        HStack {
                            Label("Import Chat History", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isImportingChatHistory {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPreparingChatHistoryExport || isImportingChatHistory)
                }

                Section("Diagnostics") {
                    Button {
                        Task {
                            await exportDiagnosticsArchive()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: "ladybug.fill")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                Text("Export Diagnostics Archive")
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.accentColor)
                                Spacer()
                                if isPreparingDiagnostics {
                                    ProgressView()
                                }
                            }
                            Text("Exports app/device info, connection settings, local message counts, and recent app logs as a zip — for troubleshooting with support. No private keys, seed phrases, or decrypted message content are included.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(isPreparingDiagnostics)
                }

                // Danger Zone
                Section("Actions") {
                    Button {
                        if settingsViewModel.settings.biometricSeedPhraseEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view your seed phrase") {
                                showSeedPhrase = true
                            }
                        } else {
                            showSeedPhrase = true
                        }
                    } label: {
                        Label("View Seed Phrase", systemImage: "key")
                    }
                }

                Section("Danger Zone") {
                    if dpiWarningActive {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Sync warning detected", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Message sync appears incomplete under restricted network conditions. Consider wiping and re-syncing incoming messages on a normal connection.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            if !dpiWarningEndpoint.isEmpty {
                                Text("Last failed endpoint: \(dpiWarningEndpoint)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button(role: .destructive) {
                        showWipeIncomingConfirmation = true
                    } label: {
                        Label("Wipe and re-sync incoming messages", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundColor(.red)
                    }
                    .confirmationDialog(
                        "Wipe and re-sync incoming messages",
                        isPresented: $showWipeIncomingConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Wipe Incoming Messages", role: .destructive) {
                            Task {
                                await wipeIncomingMessages()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                    Text("This removes all incoming messages locally and in iCloud, then re-syncs them from the blockchain. Your account info and sent messages are preserved.")
                    }

                    Button(role: .destructive) {
                        showWipeAccountConfirmation = true
                    } label: {
                        Label("Wipe account & messages", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundColor(.red)
                    }
                    .confirmationDialog(
                        "Wipe account & messages",
                        isPresented: $showWipeAccountConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Wipe Account & Messages", role: .destructive) {
                            Task {
                                await wipeAccountAndMessages(deleteCloudData: false)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes local account data and messages. CloudKit sync is disabled during the wipe and re-enabled afterward.")
                    }

                    Button(role: .destructive) {
                        showWipeAccountCloudConfirmation = true
                    } label: {
                        Label("Wipe account & messages & iCloud", systemImage: "icloud.slash")
                            .foregroundColor(.red)
                    }
                    .confirmationDialog(
                        "Wipe account & messages & iCloud",
                        isPresented: $showWipeAccountCloudConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Wipe Local & iCloud Data", role: .destructive) {
                            Task {
                                await wipeAccountAndMessages(deleteCloudData: true)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This deletes all local data and CloudKit message records. This cannot be undone.")
                    }
                }

            }
            .toast(message: toastMessage, style: toastStyle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showSeedPhrase) {
                SeedPhraseView()
            }
            .sheet(isPresented: $showDiagnosticsShareSheet) {
                if let diagnosticsArchiveURL {
                    DiagnosticsShareSheet(fileURL: diagnosticsArchiveURL)
                }
            }
            .sheet(isPresented: $showPhotoQualitySheet) {
                PhotoQualitySettingsSheet(currentPreset: settingsViewModel.settings.chatPhotoQualityPreset)
            }
            .sheet(isPresented: $showChatHistoryShareSheet) {
                if let chatHistoryArchiveURL {
                    DiagnosticsShareSheet(fileURL: chatHistoryArchiveURL)
                }
            }
            .fileImporter(
                isPresented: $showChatHistoryImporter,
                allowedContentTypes: [.json]
            ) { result in
                Task {
                    await importChatHistoryArchive(result: result)
                }
            }
            .confirmationDialog(
                "Delete Account",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        try? await walletManager.deleteWallet()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your account from this device. Make sure you have backed up your seed phrase.")
            }
        }
        .onAppear {
            refreshMessageStoreSize()
            Task { _ = try? await walletManager.refreshBalance() }
        }
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        return Text("\(exact) KAS")
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
            .onTapGesture {
                guard sompi != nil else { return }
                UIPasteboard.general.string = exact
                Haptics.success()
                showToast("Balance copied to clipboard.")
            }
    }

    private func refreshMessageStoreSize() {
        let bytes = MessageStore.shared.currentStoreSizeBytes()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        messageStoreSize = formatter.string(fromByteCount: bytes)
    }

    /// Live server round-trip - unlike `refreshMessageStoreSize()`, this isn't refreshed
    /// automatically on every settings change, since it costs a network request.
    private func refreshCloudKitStorageSize() async {
        isRefreshingCloudKitStorage = true
        defer { isRefreshingCloudKitStorage = false }
        let result = await MessageStore.shared.estimateCurrentWalletCloudKitStorage()
        switch result {
        case .success(let estimate):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let bytesText = formatter.string(fromByteCount: estimate.estimatedBytes)
            cloudKitStorageSize = "\(bytesText) (\(estimate.recordCount) records)"
        case .failure(let error):
            cloudKitStorageSize = "Unavailable"
            AppLog.log("[SettingsView] Failed to estimate CloudKit storage: \(error)")
        }
    }

    private func wipeIncomingMessages() async {
        await ChatService.shared.wipeIncomingMessagesAndResync()
        refreshMessageStoreSize()
    }

    private func wipeAccountAndMessages(deleteCloudData: Bool) async {
        let previousCloudSetting = settingsViewModel.settings.storeMessagesInICloud
        if !deleteCloudData {
            settingsViewModel.settings.storeMessagesInICloud = false
            settingsViewModel.saveSettings()
            await MessageStore.shared.reloadPersistentStores(enableCloud: false)
        } else if !previousCloudSetting {
            settingsViewModel.settings.storeMessagesInICloud = true
            settingsViewModel.saveSettings()
            await MessageStore.shared.reloadPersistentStores(enableCloud: true)
        }

        // Clear CloudKit data first (before store is removed)
        if deleteCloudData {
            if let error = await MessageStore.shared.purgeCloudKitData() {
                AppLog.log("[Settings] CloudKit purge failed: %@", error.localizedDescription)
            }
        }

        if !deleteCloudData {
            await MessageStore.shared.destroyLocalStoreFiles()
            await MessageStore.shared.reloadPersistentStores(enableCloud: false)
        }

        // deleteWallet() handles clearing the message store before removing it
        try? await walletManager.deleteWallet(preserveOutgoingMessages: false)

        // Clear chat state (skipStoreClear=true since deleteWallet already cleared messages)
        ChatService.shared.clearAllData(skipStoreClear: true)
        ContactsManager.shared.deleteAllContacts()

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        let keysToRemove = [
            "kachat_wallet",
            "kachat_seed_phrase",
            "kachat_contacts",
            "kachat_messages",
            "kachat_settings",
            "kachat_conversations",
            "kachat_conversation_aliases",
            "kachat_our_aliases",
            "kachat_last_poll_time"
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        UserDefaults.standard.synchronize()
        settingsViewModel.resetToDefaults()

        if !deleteCloudData {
            settingsViewModel.settings.storeMessagesInICloud = previousCloudSetting
            settingsViewModel.saveSettings()
            await MessageStore.shared.reloadPersistentStores(enableCloud: previousCloudSetting)
        }
        refreshMessageStoreSize()
    }

    private func exportChatHistoryArchive() async {
        if isPreparingChatHistoryExport { return }
        isPreparingChatHistoryExport = true
        defer { isPreparingChatHistoryExport = false }

        do {
            let fileURL = try await ChatService.shared.exportChatHistoryArchive()
            chatHistoryArchiveURL = fileURL
            showChatHistoryShareSheet = true
        } catch {
            AppLog.log("[Settings] Failed to export chat history: %@", error.localizedDescription)
            showToast(error.localizedDescription, style: .error)
        }
    }

    private func importChatHistoryArchive(result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            showToast("Failed to open archive: \(error.localizedDescription)", style: .error)
        case .success(let fileURL):
            guard !isImportingChatHistory else { return }
            isImportingChatHistory = true
            defer { isImportingChatHistory = false }

            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let summary = try await ChatService.shared.importChatHistoryArchive(data)
                refreshMessageStoreSize()
                if summary.filledSentContentCount > 0 {
                    showToast(
                        "Imported \(summary.messageCount) messages from \(summary.conversationCount) chats. Filled \(summary.filledSentContentCount) sent messages.",
                        style: .success
                    )
                } else {
                    showToast(
                        "Imported \(summary.messageCount) messages from \(summary.conversationCount) chats.",
                        style: .success
                    )
                }
            } catch {
                AppLog.log("[Settings] Failed to import chat history: %@", error.localizedDescription)
                showToast("Import failed: \(error.localizedDescription)", style: .error)
            }
        }
    }

    private func exportDiagnosticsArchive() async {
        if isPreparingDiagnostics { return }
        isPreparingDiagnostics = true
        defer { isPreparingDiagnostics = false }

        let archive = await buildDiagnosticsArchive()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folderName = "kasia-diagnostics-\(timestamp)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(folderName).zip")

        do {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                try FileManager.default.removeItem(at: tempDir)
            }
            if FileManager.default.fileExists(atPath: zipURL.path) {
                try FileManager.default.removeItem(at: zipURL)
            }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(archive)
            let jsonURL = tempDir.appendingPathComponent("diagnostics.json")
            try data.write(to: jsonURL, options: .atomic)

            let logs = await collectAppLogs()
            let logData = logs.data(using: .utf8, allowLossyConversion: true) ?? Data()
            let logsURL = tempDir.appendingPathComponent("app.log")
            try logData.write(to: logsURL, options: .atomic)

            let zipFiles = [
                SimpleZipWriter.FileEntry(name: "diagnostics.json", data: data),
                SimpleZipWriter.FileEntry(name: "app.log", data: logData)
            ]
            try SimpleZipWriter.createZip(at: zipURL, files: zipFiles)
            diagnosticsArchiveURL = zipURL
            showDiagnosticsShareSheet = true
        } catch {
            AppLog.log("[Settings] Failed to export diagnostics: %@", error.localizedDescription)
            showToast("Failed to export diagnostics.", style: .error)
        }
    }

    private func buildDiagnosticsArchive() async -> DiagnosticsArchive {
        let settings = AppSettings.load()
        let nodePoolRecords = await NodePoolService.shared.allNodeRecords()
        let nodeStateCounts = await NodePoolService.shared.nodeStateCounts()
        let totalUnread = ChatService.shared.conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
        let sharedUnread = SharedDataManager.getUnreadCount()
        let messageStoreBytes = MessageStore.shared.currentStoreSizeBytes()
        let storeDiagnostics = MessageStore.shared.currentStoreDiagnostics()

        let appInfo = DiagnosticsArchive.AppInfo(
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        )

        let deviceInfo = DiagnosticsArchive.DeviceInfo(
            name: UIDevice.current.name,
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )

        let nodePoolSummary = DiagnosticsArchive.NodePoolSummary(
            counts: nodeStateCounts.mapValues { $0 },
            totalRecords: nodePoolRecords.count
        )

        let lastPayloadLenValue = SharedDataManager.sharedDefaultsValue(forKey: "last_push_payload_len")
        let lastPayloadLen = (lastPayloadLenValue as? Int) ?? (lastPayloadLenValue as? NSNumber)?.intValue

        let lastTsValue = SharedDataManager.sharedDefaultsValue(forKey: "last_push_ts")
        let lastTimestamp = (lastTsValue as? Int64) ?? (lastTsValue as? NSNumber)?.int64Value

        let pushDebug = DiagnosticsArchive.PushDebug(
            lastPayload: SharedDataManager.sharedDefaultsValue(forKey: "last_push_payload") as? String,
            lastPayloadLength: lastPayloadLen,
            lastType: SharedDataManager.sharedDefaultsValue(forKey: "last_push_type") as? String,
            lastSender: SharedDataManager.sharedDefaultsValue(forKey: "last_push_sender") as? String,
            lastTxId: SharedDataManager.sharedDefaultsValue(forKey: "last_push_tx_id") as? String,
            lastTimestamp: lastTimestamp,
            lastDecryptStatus: SharedDataManager.sharedDefaultsValue(forKey: "last_push_decrypt_status") as? String
        )

        return DiagnosticsArchive(
            generatedAt: Date(),
            app: appInfo,
            device: deviceInfo,
            settings: settings,
            unreadCount: totalUnread,
            sharedUnreadCount: sharedUnread,
            messageStoreBytes: messageStoreBytes,
            messageStoreDiagnostics: DiagnosticsArchive.MessageStoreDiagnostics(
                totalMessages: storeDiagnostics.totalMessages,
                distinctTxIds: storeDiagnostics.distinctTxIds,
                placeholderCount: storeDiagnostics.placeholderCount,
                outgoingCount: storeDiagnostics.outgoingCount,
                incomingCount: storeDiagnostics.incomingCount
            ),
            nodePool: nodePoolSummary,
            nodePoolRecords: nodePoolRecords,
            pushDebug: pushDebug
        )
    }

    private func collectAppLogs() async -> String {
        if #available(iOS 15.0, macOS 12.0, *) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let start = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
                let entries = try store.getEntries(at: start)
                var lines: [String] = []
                lines.reserveCapacity(5000)
                let formatter = ISO8601DateFormatter()
                let bundleId = Bundle.main.bundleIdentifier ?? "com.kachat.app"
                var count = 0
                for case let entry as OSLogEntryLog in entries {
                    let subsystem = entry.subsystem
                    let category = entry.category
                    let message = entry.composedMessage
                    let lower = message.lowercased()
                    let isAppLog = subsystem.isEmpty || subsystem == bundleId || subsystem.hasPrefix("com.kachat")
                    let isErrorLog = lower.contains("error") || lower.contains("fail")
                    guard isAppLog || isErrorLog else { continue }

                    let date = formatter.string(from: entry.date)
                    let line = "\(date) [\(String(describing: entry.level))] \(subsystem) \(category): \(message)"
                    lines.append(line)
                    count += 1
                    if count >= 5000 { break }
                }
                return lines.joined(separator: "\n")
            } catch {
                return "Failed to export logs: \(error.localizedDescription)"
            }
        }
        return "Log export not supported on this OS version."
    }

    private func handleSystemContactsSyncToggle(_ enabled: Bool) {
        settingsViewModel.settings.syncSystemContacts = enabled
        settingsViewModel.saveSettings()

        guard enabled else { return }

        Task {
            let granted = await contactsManager.requestSystemContactsAccess()
            if !granted {
                await MainActor.run {
                    settingsViewModel.settings.syncSystemContacts = false
                    settingsViewModel.saveSettings()
                    showToast("Contacts permission denied. Sync disabled.", style: .error)
                }
            }
        }
    }

    private func handleAutoCreateSystemContactsToggle(_ enabled: Bool) {
        settingsViewModel.settings.autoCreateSystemContacts = enabled
        settingsViewModel.saveSettings()
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

}

/// Lets the user customize the 6 emojis shown in the double-tap quick-reaction bar
/// (`QuickReactionBarView`/Android's `QuickReactionBar`) - defaults to
/// `AppSettings.defaultQuickReactionEmojis` until changed here.
struct QuickReactionEmojisSettingsView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @State private var editingSlotIndex: Int?

    private var emojis: [String] {
        settingsViewModel.settings.effectiveQuickReactionEmojis
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ForEach(emojis.indices, id: \.self) { index in
                        Button {
                            editingSlotIndex = index
                        } label: {
                            Text(emojis[index])
                                .font(.system(size: 30))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.systemGray5))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                Text("Tap an emoji to replace it with a different one.")
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    settingsViewModel.settings.quickReactionEmojis = AppSettings.defaultQuickReactionEmojis
                    settingsViewModel.saveSettings()
                }
            }
        }
        .navigationTitle("Quick Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { editingSlotIndex.map { QuickReactionSlotSelection(index: $0) } },
            set: { if $0 == nil { editingSlotIndex = nil } }
        )) { selection in
            NavigationStack {
                DesktopEmojiPickerView { emoji in
                    var updated = emojis
                    updated[selection.index] = emoji
                    settingsViewModel.settings.quickReactionEmojis = updated
                    settingsViewModel.saveSettings()
                    editingSlotIndex = nil
                }
                .padding()
                .navigationTitle("Choose Emoji")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingSlotIndex = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct QuickReactionSlotSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

struct NotificationsSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var pushManager: PushNotificationManager

    @State private var isEnablingPush = false
    @State private var notificationPermissionDenied = false
    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(
                    get: { settingsViewModel.settings.notificationMode },
                    set: { newValue in
                        handleNotificationModeChange(to: newValue)
                    }
                )) {
                    ForEach(NotificationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isEnablingPush)

                if settingsViewModel.settings.notificationMode == .remotePush {
                    if pushManager.isRegistered {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                                Text("Registered")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let watchedCount = pushManager.watchedAddressesCount, watchedCount > 0 {
                            HStack {
                                Text("Watching")
                                Spacer()
                                Text("\(watchedCount) contacts")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text("Not registered")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if isEnablingPush {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Enabling remote push...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    switch settingsViewModel.settings.notificationMode {
                    case .disabled:
                        Text("Notifications are disabled.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .remotePush:
                        Text("Receive notifications when contacts send messages, even when the app is closed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Push Notifications")
            }

            Section {
                Toggle("Play sound", isOn: $settingsViewModel.settings.incomingNotificationSoundEnabled)
                    .onChange(of: settingsViewModel.settings.incomingNotificationSoundEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }

                Toggle("Vibration", isOn: $settingsViewModel.settings.incomingNotificationVibrationEnabled)
                    .onChange(of: settingsViewModel.settings.incomingNotificationVibrationEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }
            } header: {
                Text("Sound & Vibration")
            } footer: {
                Text("Used when a contact has no custom notification mode set.")
            }

            Section("Per Contact") {
                Text("Set per-contact notification mode in each chat's info screen: Off, No Sound, or Sound.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .toast(message: toastMessage, style: toastStyle)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Notifications Disabled", isPresented: $notificationPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To receive notifications, please enable them in Settings.")
        }
    }

    private func handleNotificationModeChange(to newMode: NotificationMode) {
        let previousMode = settingsViewModel.settings.notificationMode
        guard newMode != previousMode else { return }

        switch newMode {
        case .disabled:
            if previousMode == .remotePush {
                disablePushNotifications()
            }
            settingsViewModel.settings.notificationMode = .disabled
            settingsViewModel.saveSettings()
        case .remotePush:
            settingsViewModel.settings.notificationMode = .remotePush
            settingsViewModel.saveSettings()
            ChatService.shared.stopPollingTimerOnly()
            BackgroundTaskManager.shared.cancelBackgroundFetch()
            enablePushNotifications(previousMode: previousMode)
        }
    }

    private func enablePushNotifications(previousMode: NotificationMode) {
        isEnablingPush = true
        Task {
            do {
                try await pushManager.requestPermissionAndRegisterAndWaitForIndexer()
                settingsViewModel.settings.notificationMode = .remotePush
                settingsViewModel.saveSettings()
            } catch {
                AppLog.log("[Settings] Failed to enable push: %@", error.localizedDescription)
                settingsViewModel.settings.notificationMode = previousMode
                settingsViewModel.saveSettings()
                if case PushError.permissionDenied = error {
                    notificationPermissionDenied = true
                }
                showToast("Push subscription failed.", style: .error)
            }
            isEnablingPush = false
        }
    }

    private func disablePushNotifications() {
        Task {
            await pushManager.unregister()
            settingsViewModel.saveSettings()
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        toastStyle = style
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
}

private struct DiagnosticsArchive: Codable {
    struct AppInfo: Codable {
        let bundleId: String
        let version: String
        let build: String
    }

    struct DeviceInfo: Codable {
        let name: String
        let model: String
        let systemName: String
        let systemVersion: String
    }

    struct NodePoolSummary: Codable {
        let counts: [NodeState: Int]
        let totalRecords: Int
    }

    struct PushDebug: Codable {
        let lastPayload: String?
        let lastPayloadLength: Int?
        let lastType: String?
        let lastSender: String?
        let lastTxId: String?
        let lastTimestamp: Int64?
        let lastDecryptStatus: String?
    }

    struct MessageStoreDiagnostics: Codable {
        let totalMessages: Int
        let distinctTxIds: Int
        let placeholderCount: Int
        let outgoingCount: Int
        let incomingCount: Int
    }

    let generatedAt: Date
    let app: AppInfo
    let device: DeviceInfo
    let settings: AppSettings
    let unreadCount: Int
    let sharedUnreadCount: Int
    let messageStoreBytes: Int64
    let messageStoreDiagnostics: MessageStoreDiagnostics
    let nodePool: NodePoolSummary
    let nodePoolRecords: [NodeRecord]
    let pushDebug: PushDebug
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum SimpleZipWriter {
    struct FileEntry {
        let name: String
        let data: Data
    }

    static func createZip(at url: URL, files: [FileEntry]) throws {
        var localFileHeaders: [Data] = []
        var centralDirectory: [Data] = []
        var offset: UInt32 = 0

        for file in files {
            let crc = crc32(file.data)
            let fileNameData = Data(file.name.utf8)
            let localHeader = buildLocalFileHeader(
                fileNameLength: UInt16(fileNameData.count),
                crc32: crc,
                size: UInt32(file.data.count)
            )
            var localEntry = Data()
            localEntry.append(localHeader)
            localEntry.append(fileNameData)
            localEntry.append(file.data)
            localFileHeaders.append(localEntry)

            let centralHeader = buildCentralDirectoryHeader(
                fileNameLength: UInt16(fileNameData.count),
                crc32: crc,
                size: UInt32(file.data.count),
                localHeaderOffset: offset
            )
            var centralEntry = Data()
            centralEntry.append(centralHeader)
            centralEntry.append(fileNameData)
            centralDirectory.append(centralEntry)

            offset += UInt32(localEntry.count)
        }

        let centralStart = offset
        var centralData = Data()
        for entry in centralDirectory {
            centralData.append(entry)
            offset += UInt32(entry.count)
        }

        let endRecord = buildEndOfCentralDirectory(
            totalEntries: UInt16(files.count),
            centralDirectorySize: UInt32(centralData.count),
            centralDirectoryOffset: centralStart
        )

        var archive = Data()
        for entry in localFileHeaders {
            archive.append(entry)
        }
        archive.append(centralData)
        archive.append(endRecord)

        try archive.write(to: url, options: .atomic)
    }

    private static func buildLocalFileHeader(fileNameLength: UInt16, crc32: UInt32, size: UInt32) -> Data {
        var data = Data()
        data.appendUInt32(0x04034b50)
        data.appendUInt16(20)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(crc32)
        data.appendUInt32(size)
        data.appendUInt32(size)
        data.appendUInt16(fileNameLength)
        data.appendUInt16(0)
        return data
    }

    private static func buildCentralDirectoryHeader(
        fileNameLength: UInt16,
        crc32: UInt32,
        size: UInt32,
        localHeaderOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x02014b50)
        data.appendUInt16(20)
        data.appendUInt16(20)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(crc32)
        data.appendUInt32(size)
        data.appendUInt32(size)
        data.appendUInt16(fileNameLength)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(0)
        data.appendUInt32(localHeaderOffset)
        return data
    }

    private static func buildEndOfCentralDirectory(
        totalEntries: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendUInt32(0x06054b50)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(totalEntries)
        data.appendUInt16(totalEntries)
        data.appendUInt32(centralDirectorySize)
        data.appendUInt32(centralDirectoryOffset)
        data.appendUInt16(0)
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

struct SeedPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var walletManager: WalletManager
    @State private var seedPhrase: SeedPhrase?
    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var error: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Warning
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("Anyone with your seed phrase can access your account. Never share it with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let seedPhrase = seedPhrase {
                    if isRevealed {
                        // Seed phrase grid (protected from screenshots)
                        SecureView {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(Array(seedPhrase.words.enumerated()), id: \.offset) { index, word in
                                    HStack(spacing: 4) {
                                        Text("\(index + 1).")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 18, alignment: .trailing)
                                        Text(word)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.6)
                                            .allowsTightening(true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }

                        // Seed-phrase copy is intentionally NOT offered - the recovery phrase must
                        // be transcribed by hand. The private key hex may be copied here (view
                        // seed-phrase mode), but the clipboard is auto-wiped 30s later.
                        VStack(spacing: 12) {
                            Button {
                                guard let privateKey = walletManager.getPrivateKey() else {
                                    showToast("Private key unavailable.", style: .error)
                                    return
                                }
                                copySensitiveToClipboard(privateKey.hexString)
                                Haptics.success()
                                showToast("Private key hex copied. Clipboard will clear in 30s.")
                            } label: {
                                Label("Copy Private Key Hex", systemImage: "number")
                            }
                        }
                        .padding(.top)
                    } else {
                        Button {
                            isRevealed = true
                            let token = UUID()
                            revealToken = token
                            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                                if revealToken == token {
                                    isRevealed = false
                                }
                            }
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.largeTitle)
                                Text("Tap to reveal seed phrase")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(60)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .foregroundColor(.secondary)
                    }
                } else if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Seed Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toast(message: toastMessage, style: toastStyle)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSeedPhrase()
            }
        }
    }

    private func loadSeedPhrase() {
        do {
            seedPhrase = try KeychainService.shared.loadSeedPhrase()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copies sensitive material (the private key hex) to the clipboard and auto-wipes it 30s
    /// later - but only if nothing else has overwritten the clipboard in the meantime. This bounds
    /// the window in which other apps or the system clipboard history can read it.
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.string = value
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

struct KaspaExplorerSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(KaspaExplorer.allCases, id: \.self) { explorer in
                    Button {
                        settingsViewModel.kaspaExplorer = explorer
                    } label: {
                        HStack {
                            Text(explorer.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if settingsViewModel.settings.kaspaExplorer == explorer {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("Explorer")
            } footer: {
                Text("Used to build \"view transaction\" links throughout the app.")
            }
        }
        .navigationTitle("Kaspa Explorer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var networkType: NetworkType = .mainnet
    @State private var indexerURL: String = ""
    @State private var kaPostIndexerURL: String = ""
    @State private var broadcastIndexerURL: String = ""
    @State private var pushIndexerURL: String = ""
    @State private var knsBaseURL: String = ""
    @State private var kaspaRestAPIURL: String = ""
    @State private var trustedNodeValidationError: String?

    @State private var newSavedNodeLabel: String = ""
    @State private var newSavedNodeAddress: String = ""
    @State private var savedNodeAddressError: String?

    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        Form {
            Section {
                Picker("Network", selection: $networkType) {
                    ForEach(NetworkType.allCases, id: \.self) { network in
                        Text(network.displayName).tag(network)
                    }
                }
                .onChange(of: networkType) { newValue in
                    // Update URLs to defaults for new network if they match old defaults
                    let oldNetwork = settingsViewModel.settings.networkType
                    if knsBaseURL == AppSettings.defaultKNSURL(for: oldNetwork) {
                        knsBaseURL = AppSettings.defaultKNSURL(for: newValue)
                    }
                    if kaspaRestAPIURL == AppSettings.defaultKaspaRestURL(for: oldNetwork) {
                        kaspaRestAPIURL = AppSettings.defaultKaspaRestURL(for: newValue)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Select mainnet for real transactions or testnet for testing")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexer URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://indexer.kasia.wtf", text: $indexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("KaChat Indexer")
            } footer: {
                Text("Message indexer service for chat functionality")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("KaPost Indexer URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(AppSettings.defaultKaPostIndexerURL, text: $kaPostIndexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("KaPost Indexer")
            } footer: {
                Text("K social network indexer that powers KaPosts feeds")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Broadcast Indexer URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(AppSettings.defaultBroadcastIndexerURL, text: $broadcastIndexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("Broadcast Indexer")
            } footer: {
                Text("KaChat broadcast history indexer for #kaspa and #kachat-bugs")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Push Indexer URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://indexer.kasia.wtf", text: $pushIndexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("Push Registration")
            } footer: {
                Text("Used only for push registration and updates")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("KNS API URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://api.knsdomains.org/mainnet/api/v1", text: $knsBaseURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("Kaspa Name Service")
            } footer: {
                Text("KNS domain resolution service")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kaspa REST API URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://api.kaspa.org", text: $kaspaRestAPIURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            } header: {
                Text("Kaspa Explorer API")
            } footer: {
                Text("REST API for transaction history and balance lookups")
            }

            Section {
                Picker(
                    "Kaspa Node",
                    selection: Binding(get: { nodeChoiceSelection }, set: { applyNodeChoice($0) })
                ) {
                    Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                    Text("Automatic Scan").tag(NodeChoice.automatic)
                    ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                        Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                            .tag(NodeChoice.saved(entry.address))
                    }
                    if case .custom(let address) = nodeChoiceSelection {
                        Text(address).tag(NodeChoice.custom(address))
                    }
                }

                if let trustedNodeValidationError {
                    Text(trustedNodeValidationError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if !settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Connected only to this node")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            } header: {
                Text("Kaspa Node")
            } footer: {
                Text("Automatic Scan discovers and connects to the best available nodes. Choosing a specific node connects only to it, without falling back to others. Doesn't affect the Indexer/KNS/REST API URLs above. Add custom addresses to the IP Address Book below to select them here.")
            }

            Section {
                TextField("Label (optional)", text: $newSavedNodeLabel)
                    .autocapitalization(.words)

                HStack {
                    TextField("host:port or grpcs://host", text: $newSavedNodeAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: newSavedNodeAddress) { _ in
                            savedNodeAddressError = nil
                        }

                    Button {
                        addSavedNodeAddress()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .disabled(newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let savedNodeAddressError {
                    Text(savedNodeAddressError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if settingsViewModel.settings.savedNodeAddresses.isEmpty {
                    Text("No saved addresses")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            if !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(entry.label)
                                Text(entry.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(entry.address)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = entry.address
                            Haptics.success()
                            showToast("Address copied.")
                        }
                    }
                    .onDelete { indexSet in
                        settingsViewModel.settings.savedNodeAddresses.remove(atOffsets: indexSet)
                        settingsViewModel.saveSettings()
                    }
                }
            } header: {
                Text("IP Address Book")
            } footer: {
                Text("Save your own node addresses here, then tap one to copy it and paste into the Kaspa Node field above.")
            }
        }
        .navigationTitle("Connection Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveSettings()
                    dismiss()
                }
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .toast(message: toastMessage, style: toastStyle)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        toastMessage = nil
        toastStyle = style
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }

    private func addSavedNodeAddress() {
        let trimmedAddress = newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return }
        guard Endpoint(url: trimmedAddress) != nil else {
            savedNodeAddressError = "Enter as host:port or grpcs://host"
            return
        }
        savedNodeAddressError = nil
        let trimmedLabel = newSavedNodeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.append(
            SavedNodeAddress(label: trimmedLabel, address: trimmedAddress)
        )
        settingsViewModel.saveSettings()
        newSavedNodeLabel = ""
        newSavedNodeAddress = ""
    }

    private func loadCurrentSettings() {
        networkType = settingsViewModel.settings.networkType
        indexerURL = settingsViewModel.settings.indexerURL
        kaPostIndexerURL = settingsViewModel.settings.kaPostIndexerURL
        broadcastIndexerURL = settingsViewModel.settings.broadcastIndexerURL
        pushIndexerURL = settingsViewModel.settings.pushIndexerURL
        knsBaseURL = settingsViewModel.settings.knsBaseURL
        kaspaRestAPIURL = settingsViewModel.settings.kaspaRestAPIURL
    }

    private func saveSettings() {
        settingsViewModel.settings.networkType = networkType
        settingsViewModel.settings.indexerURL = indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.kaPostIndexerURL = kaPostIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSettings.defaultKaPostIndexerURL : kaPostIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.broadcastIndexerURL = broadcastIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSettings.defaultBroadcastIndexerURL : broadcastIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.pushIndexerURL = pushIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.knsBaseURL = knsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.kaspaRestAPIURL = kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.saveSettings()
    }

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. a one-off address typed into the field below) - shown so
        /// the picker always reflects the real current state instead of misrepresenting it.
        case custom(String)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nodeChoiceSelection: NodeChoice {
        let normalizedTrustedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    private func applyNodeChoice(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        trustedNodeValidationError = settingsViewModel.applyTrustedNode(address)
    }
}

// MARK: - Kaspa Node (quick access from Connection Status)

/// A single dropdown for picking which node to connect to, right from the connection status
/// sheet (tap the status dot) without navigating to Settings > Connection Settings: the default
/// node (recommended), automatic discovery, or any address already saved in the IP Address Book
/// there. Managing the address book itself (adding/removing/labeling entries) still lives in
/// `ConnectionSettingsView` - this is a quick-select surface over that same underlying list, not
/// a duplicate of it.
struct KaspaNodeQuickAccessSections: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    var onToast: (String, ToastStyle) -> Void

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. entered as free text in Settings > Connection Settings) -
        /// shown so the picker always reflects the real current state instead of silently
        /// misrepresenting it as "Automatic Scan".
        case custom(String)
    }

    private var normalizedTrustedAddress: String {
        settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selection: NodeChoice {
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    var body: some View {
        Section {
            Picker(
                "Kaspa Node",
                selection: Binding(get: { selection }, set: { apply($0) })
            ) {
                Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                Text("Automatic Scan").tag(NodeChoice.automatic)
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                        .tag(NodeChoice.saved(entry.address))
                }
                if case .custom(let address) = selection {
                    Text(address)
                        .tag(NodeChoice.custom(address))
                }
            }

            if case .automatic = selection {
                // No extra row - automatic discovery is the default connection mode.
            } else {
                HStack {
                    Text("Connected only to this node")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
        } header: {
            Text("Kaspa Node")
        } footer: {
            Text("Automatic Scan discovers and connects to the best available nodes. Choosing a specific node connects only to it, without falling back to others. Manage saved addresses in Settings > Connection Settings > IP Address Book.")
        }
    }

    private func apply(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        if let error = settingsViewModel.applyTrustedNode(address) {
            onToast(error, .error)
        } else {
            onToast(choice == .automatic ? "Automatic scan enabled." : "Node updated.", .success)
        }
    }
}

// MARK: - Connection Status Indicator

struct ConnectionStatusIndicator: View {
    @EnvironmentObject var chatService: ChatService
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail = true
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .sheet(isPresented: $showDetail) {
            ConnectionStatusDetailView()
        }
    }

    private var statusColor: Color {
        switch chatService.connectionStatus {
        case .connected:
            return KasiaAPIClient.shared.isDpiSuspected
                ? Color(red: 0.0, green: 0.50, blue: 0.0)
                : .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }
}

// MARK: - Connection Status Detail View

struct ConnectionStatusDetailView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @StateObject private var nodePool = NodePoolService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isReconnecting: Bool = false
    @State private var nodeRecords: [NodeRecord] = []
    @State private var showClearPoolConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            Form {
                // Status Section
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(chatService.connectionStatus.description)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text("\(nodePool.activeProtocol) (\(nodePool.activeProtocolSecurity))")
                            .foregroundColor(.secondary)
                    }

                    if KasiaAPIClient.shared.isDpiSuspected {
                        HStack {
                            Text("DPI")
                            Spacer()
                            Text("Suspected")
                                .foregroundColor(.orange)
                        }
                        Text("Connectivity might be limited. Using HTTP/1.1 and decreased pagination for indexer requests.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let node = chatService.currentConnectedNode {
                        HStack {
                            Text("Connected Node")
                            Spacer()
                            Text(extractHost(from: node))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let latency = chatService.currentNodeLatencyMs {
                        HStack {
                            Text("Latency")
                            Spacer()
                            Text("\(latency) ms")
                                .foregroundColor(latencyColor(latency))
                        }
                    }

                    // Connected node geo info
                    if let record = connectedNodeRecord {
                        if let distKm = record.profile.geoDistanceKm {
                            HStack {
                                Text("Distance")
                                Spacer()
                                Text(formatDistance(distKm))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let cc = record.profile.countryCode {
                            HStack {
                                Text("Country")
                                Spacer()
                                Text(cc)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Indexer endpoint
                    HStack {
                        Text("Indexer")
                        Spacer()
                        Text(extractHost(from: settingsViewModel.settings.indexerURL))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Push register endpoint (only if different from indexer)
                    if settingsViewModel.settings.pushIndexerURL != settingsViewModel.settings.indexerURL {
                        HStack {
                            Text("Push Register")
                            Spacer()
                            Text(extractHost(from: settingsViewModel.settings.pushIndexerURL))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack {
                        Text("Last Sync")
                        Spacer()
                        Text(lastSyncText)
                            .foregroundColor(lastSyncColor)
                    }
                } header: {
                    Text("Connection Status")
                }

                // Pool Statistics Section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text("Active")
                                    .font(.caption)
                            }
                            Text("\(nodePool.activeCount)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            HStack(spacing: 4) {
                                Circle().fill(.blue).frame(width: 8, height: 8)
                                Text("Verified")
                                    .font(.caption)
                            }
                            Text("\(nodePool.verifiedCount)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                Circle().fill(.gray).frame(width: 8, height: 8)
                                Text("Total")
                                    .font(.caption)
                            }
                            Text("\(nodePool.totalNodeCount)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Text("Pool Health")
                        Spacer()
                        Text(poolHealthDescription)
                            .foregroundColor(poolHealthColor)
                    }
                } header: {
                    Text("Pool Status")
                }

                // Pool Management Section
                Section {
                    Button {
                        Task {
                            await nodePool.refreshPool()
                        }
                    } label: {
                        HStack {
                            Text("Refresh Pool")
                            Spacer()
                            if nodePool.isRefreshing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(nodePool.isRefreshing || isReconnecting)

                    Button(role: .destructive) {
                        showClearPoolConfirm = true
                    } label: {
                        Text("Clear Connection Pool")
                    }
                    .disabled(nodePool.isRefreshing || isReconnecting)

                    Button {
                        Task {
                            await reconnect()
                        }
                    } label: {
                        HStack {
                            Text("Reconnect")
                            Spacer()
                            if isReconnecting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(nodePool.isRefreshing || isReconnecting)
                } header: {
                    Text("Actions")
                } footer: {
                    if let endpoint = nodePool.primaryEndpoint {
                        Text("Primary: \(endpoint.host)")
                    }
                }

                KaspaNodeQuickAccessSections(onToast: showToast)

                // Active Nodes Section
                Section {
                    let activeNodes = nodeRecords.filter { $0.state == .active }
                    if activeNodes.isEmpty {
                        Text("No active nodes")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(activeNodes) { record in
                            ConnectionNodeRow(
                                record: record,
                                isConnected: record.endpoint.url == chatService.currentConnectedNode
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = record.endpoint.key
                                Haptics.success()
                                showToast("Node endpoint copied.")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active Nodes")
                        Spacer()
                        Text("\(nodePool.activeCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("Tap a node to copy host:port.")
                }

                // All Nodes Section
                Section {
                    let sortedNodes = nodeRecords.sorted { a, b in
                        // Sort by state priority: active > verified > profiled > candidate > suspect > quarantined
                        if a.state.rawValue != b.state.rawValue {
                            return a.state.rawValue > b.state.rawValue
                        }
                        // Then by latency (lower is better)
                        let aLatency = a.health.latencyMs.value ?? a.health.globalLatencyMs.value ?? 9999
                        let bLatency = b.health.latencyMs.value ?? b.health.globalLatencyMs.value ?? 9999
                        return aLatency < bLatency
                    }

                    if sortedNodes.isEmpty {
                        Text("No nodes discovered")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(sortedNodes) { record in
                            AllNodesRow(record: record)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "server.rack")
                            .font(.caption)
                        Text("All Nodes")
                        Spacer()
                        Text("\(nodeRecords.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("All discovered nodes sorted by state and latency. Nodes are deduplicated by host:port.")
                }
        }
        .alert("Clear connection pool?", isPresented: $showClearPoolConfirm) {
            Button("Clear", role: .destructive) {
                Task {
                    await nodePool.clearConnectionPool()
                    await reconnect()
                    await reloadNodeRecords()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes discovered nodes, disconnects current sessions, and restarts discovery.")
        }
        .toast(message: toastMessage, style: toastStyle)
        .navigationTitle("Connection Status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await refreshNodeRecordsContinuously()
            }
        }
    }

    private var poolHealthDescription: String {
        switch nodePool.poolHealth {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .critical: return "Critical"
        case .failed: return "Failed"
        }
    }

    private var poolHealthColor: Color {
        switch nodePool.poolHealth {
        case .healthy: return .green
        case .degraded: return .orange
        case .critical: return .red
        case .failed: return .red
        }
    }

    private var statusColor: Color {
        switch chatService.connectionStatus {
        case .connected:
            return KasiaAPIClient.shared.isDpiSuspected
                ? Color(red: 0.0, green: 0.50, blue: 0.0)
                : .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var connectedNodeRecord: NodeRecord? {
        guard let primary = nodePool.primaryEndpoint else { return nil }
        return nodeRecords.first { $0.endpoint.key == primary.key }
    }

    private var lastSyncText: String {
        if chatService.isSyncInProgress {
            return "in progress"
        }
        if let lastSync = chatService.lastSuccessfulSyncDate {
            return formatDate(lastSync)
        }
        return "Never"
    }

    private var lastSyncColor: Color {
        chatService.isSyncInProgress ? .orange : .secondary
    }

    private func extractHost(from url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return url
        }
        return host
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km)) km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        toastMessage = nil
        toastStyle = style
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }

    private func reconnect() async {
        isReconnecting = true
        defer { isReconnecting = false }

        let settings = AppSettings.load()

        AppLog.log("[ConnectionStatus] Starting reconnect via NodePoolService...")

        // Disconnect current subscription
        nodePool.disconnect()

        // Small delay to ensure clean disconnect
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Reconnect via node pool
        do {
            try await nodePool.connect(network: settings.networkType)
            AppLog.log("[ConnectionStatus] Connected via NodePool, activeNodes=%d",
                  nodePool.activeNodeCount)

            // Small delay to let connections stabilize
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Re-setup subscriptions
            AppLog.log("[ConnectionStatus] Setting up subscriptions...")
            await chatService.setupUtxoSubscriptionAfterReconnect()
            AppLog.log("[ConnectionStatus] Subscription setup complete, isSubscribed=%@",
                  chatService.isRpcSubscribed ? "true" : "false")

            // Refresh node list
            await reloadNodeRecords()
        } catch {
            AppLog.log("[ConnectionStatus] Reconnect failed: %@", error.localizedDescription)
        }
    }

    private func reloadNodeRecords() async {
        nodeRecords = await nodePool.allNodeRecords()
    }

    private func refreshNodeRecordsContinuously() async {
        await reloadNodeRecords()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }
            await reloadNodeRecords()
        }
    }
}

// MARK: - Connection Node Row (POOLS_v2)

private struct ConnectionNodeRow: View {
    let record: NodeRecord
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Connection indicator
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Origin indicator
                switch record.origin {
                case .userAdded:
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                case .seed:
                    Image(systemName: "shield.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                case .discovered:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Text(verbatim: record.endpoint.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Text(record.state.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.2))
                    .foregroundColor(stateColor)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // Origin label
                Text(record.origin.displayName)
                    .font(.caption2)
                    .foregroundColor(originColor)

                // Latency
                if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                    Text("\(Int(latency))ms")
                        .font(.caption)
                        .foregroundColor(latencyColor(Int(latency)))
                }

                // Geo distance
                if let distKm = record.profile.geoDistanceKm {
                    Text(formatDistance(distKm))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Country code
                if let cc = record.profile.countryCode {
                    Text(cc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // DPI check failed
                if record.profile.peerInfoOk == false {
                    HStack(spacing: 2) {
                        Image(systemName: "network.slash")
                            .font(.caption2)
                        Text("DPI")
                            .font(.caption2)
                    }
                    .foregroundColor(.red)
                }

                // Success/failure counts
                if record.health.consecutiveSuccesses > 0 {
                    Text("\(record.health.consecutiveSuccesses)✓")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if record.health.consecutiveFailures > 0 {
                    Text("\(record.health.consecutiveFailures)✗")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                // DAA score (if available)
                if let daa = record.profile.virtualDaaScore {
                    Text("DAA: \(formatDaa(daa))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private var originColor: Color {
        switch record.origin {
        case .userAdded: return .yellow
        case .seed: return .blue
        case .discovered: return .secondary
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDaa(_ daa: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: daa)) ?? "\(daa)"
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

// MARK: - All Nodes Row (Compact)

private struct AllNodesRow: View {
    let record: NodeRecord

    var body: some View {
        HStack(spacing: 8) {
            // State indicator
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            // Origin indicator
            switch record.origin {
            case .userAdded:
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.caption2)
            case .seed:
                Image(systemName: "shield.fill")
                    .foregroundColor(.blue)
                    .font(.caption2)
            case .discovered:
                EmptyView()
            }

            // Host:port
            Text(verbatim: "\(record.endpoint.host):\(record.endpoint.port)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            Spacer()

            // Country code
            if let cc = record.profile.countryCode {
                Text(cc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Geo distance
            if let distKm = record.profile.geoDistanceKm {
                Text(formatDistance(distKm))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // DPI check failed
            if record.profile.peerInfoOk == false {
                Image(systemName: "network.slash")
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            // Latency
            if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                Text("\(Int(latency))ms")
                    .font(.caption2)
                    .foregroundColor(latencyColor(Int(latency)))
            }

            // State badge
            Text(record.state.displayName)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(stateColor.opacity(0.2))
                .foregroundColor(stateColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
        .environmentObject(SettingsViewModel())
        .environmentObject(PushNotificationManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
}
