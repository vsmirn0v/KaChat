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

    // Restore-from-backup state lives on this singleton (NOT view @State) so the restore Task
    // survives any view teardown; this view only presents the blocking modal and observes.
    @ObservedObject private var restoreCoordinator = BackupRestoreCoordinator.shared
    // Same ownership rule for the Danger Zone wipe-and-resync: the task lives on this singleton,
    // this view only presents the blocking modal and observes.
    @ObservedObject private var resyncCoordinator = IncomingResyncCoordinator.shared

    @State private var showSeedPhrase = false
    @State private var showDeleteConfirmation = false
    @State private var showWipeIncomingConfirmation = false
    @State private var showResyncChatPicker = false
    /// Selection handed back by the chat picker sheet; the resync starts from the sheet's
    /// onDismiss so the fullScreenCover is never presented while the sheet is still animating out.
    @State private var pendingResyncSelection: [String]?
    @State private var showWipeAccountConfirmation = false
    @State private var showWipeICloudConfirmation = false
    @State private var isWipingICloud = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var messageStoreSize = "Unknown"
    @State private var chatHistoryArchiveURL: URL?
    @State private var showChatHistoryShareSheet = false
    @State private var showChatHistoryImporter = false
    @State private var isPreparingChatHistoryExport = false
    @State private var showPhotoQualitySheet = false

    /// Mirrors the ACTIVE ACCOUNT's per-wallet Chats Privacy flag (fresh-address payment
    /// pools) - seeded from storage when the Chats page appears, written through on change.
    /// Per-account, not part of the global AppSettings blob: see
    /// `AppSettings.chatsPrivacyEnabled(for:)`.
    @State private var chatsPrivacyEnabled = true
    @AppStorage(MessageStore.dpiCorruptionWarningKey) private var dpiWarningActive = false
    @AppStorage(MessageStore.dpiCorruptionWarningEndpointKey) private var dpiWarningEndpoint = ""
    @AppStorage(MessageStore.dpiCorruptionWarningDateKey) private var dpiWarningDate: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    customizationPage
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    securityPage
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    connectionPage
                }
                settingsCategoryRow("Notifications", icon: "bell.badge", tint: .accentColor) {
                    NotificationsHubPage()
                }
                settingsCategoryRow("Chats", icon: "bubble.left.and.bubble.right", tint: .accentColor) {
                    chatsPage
                }
                settingsCategoryRow("Contacts", icon: "person.2", tint: .accentColor) {
                    contactsPage
                }
                settingsCategoryRow("Storage", icon: "internaldrive", tint: .accentColor) {
                    storagePage
                }
                settingsCategoryRow("Chat History", icon: "clock.arrow.circlepath", tint: .accentColor) {
                    chatHistoryPage
                }
                settingsCategoryRow("Diagnostics", icon: "stethoscope", tint: .accentColor) {
                    diagnosticsPage
                }
                // Its own section, always here: Profile only offers the gift while there is
                // something to claim, so once claimed this is the one place its state - and the
                // reset gesture - stays reachable.
                settingsCategoryRow("Gift", icon: "gift", tint: .accentColor) {
                    GiftSettingsPage()
                }
                // Direct action, not a sub-page: straight into the seed phrase (behind the
                // biometric gate when enabled).
                Button {
                    if settingsViewModel.settings.biometricSeedPhraseEnabled {
                        DeviceAuth.authenticate(reason: "Unlock to view your seed phrase") {
                            showSeedPhrase = true
                        }
                    } else {
                        showSeedPhrase = true
                    }
                } label: {
                    Label {
                        Text("View Seed Phrase")
                            .foregroundColor(.red)
                    } icon: {
                        Image(systemName: "key")
                            .foregroundColor(.accentColor)
                    }
                }
                settingsCategoryRow("Danger Zone", icon: "exclamationmark.triangle", tint: .red) {
                    dangerZonePage
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
            // Blocking restore modal: presented for the whole Settings stack (covers both the
            // Nextcloud restore page and the local-file import) the moment a restore starts.
            // The binding's setter is a no-op, so the ONLY way out is the modal's own buttons
            // calling BackupRestoreCoordinator.dismiss(), which refuses while a restore runs.
            .fullScreenCover(isPresented: Binding(
                get: { restoreCoordinator.isPresentingModal },
                set: { _ in }
            )) {
                ChatRestoreProgressModal()
            }
            .onChange(of: restoreCoordinator.phase) { phase in
                if case .success = phase {
                    refreshMessageStoreSize()
                }
            }
            // Blocking wipe-and-resync modal (Danger Zone): same inescapable pattern as the
            // restore modal above - no-op binding setter, exits only via the modal's own buttons.
            .fullScreenCover(isPresented: Binding(
                get: { resyncCoordinator.isPresentingModal },
                set: { _ in }
            )) {
                IncomingResyncProgressModal()
            }
            .onChange(of: resyncCoordinator.phase) { phase in
                if case .success = phase {
                    refreshMessageStoreSize()
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

    // MARK: - Settings categories (each section is its own page)

    private var customizationPage: some View {
        Form {
            Section("Customization") {
                    // Appearance/Language/Currency are extracted so the accounts-screen
                    // App Settings can reuse the exact same rows (one source of truth) -
                    // Customize Dock + Show Setup Guides below stay here only: the dock is
                    // per-account and the guides need an active wallet.
                    AppWideCustomizationPickers()

                    NavigationLink {
                        MenuVisibilityView()
                    } label: {
                        Label("Customize Dock", systemImage: "list.bullet")
                    }
                }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var securityPage: some View {
        SecuritySettingsPage()
    }

    private var connectionPage: some View {
        ConnectionHubPage()
    }

    private var chatsPage: some View {
        Form {
            Section("Chats") {
                    Toggle("Show Fee Estimate", isOn: $settingsViewModel.settings.showFeeEstimate)
                        .onChange(of: settingsViewModel.settings.showFeeEstimate) { _ in
                            settingsViewModel.saveSettings()
                        }

                    Toggle("Require approval for photos from new contacts", isOn: $settingsViewModel.settings.requirePhotoApprovalForNewContacts)
                        .onChange(of: settingsViewModel.settings.requirePhotoApprovalForNewContacts) { _ in
                            settingsViewModel.saveSettings()
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

        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var contactsPage: some View {
        Form {
            Section("Contacts") {
                    Toggle("Sync system contacts", isOn: Binding(
                        get: { settingsViewModel.settings.syncSystemContacts },
                        set: { enabled in
                            handleSystemContactsSyncToggle(enabled)
                        }
                    ))

                    Text("Uses your device contacts to match and enrich Kaspa contacts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Storage hub: a category list like the main Settings screen — each provider row leads
    /// into its own screen.
    private var storagePage: some View {
        Form {
            Section {
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
            } header: {
                Text("On This Device")
            } footer: {
                Text("How long messages are kept on this device, and how much space they use. Applies before any cloud storage.")
            }

            Section("Cloud Storage") {
                settingsCategoryRow("iCloud", icon: "icloud", tint: .accentColor) {
                    iCloudStoragePage
                }
                settingsCategoryRow("Nextcloud", icon: "externaldrive.connected.to.line.below", tint: .accentColor) {
                    nextcloudStoragePage
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var iCloudStoragePage: some View {
        Form {
            Section("iCloud") {
                Toggle("Store encrypted messages in iCloud CloudKit", isOn: $settingsViewModel.settings.storeMessagesInICloud)
                    .onChange(of: settingsViewModel.settings.storeMessagesInICloud) { newValue in
                        settingsViewModel.saveSettings()
                        refreshMessageStoreSize()
                        // One cloud at a time: turning iCloud on turns Nextcloud Automatic
                        // Sync off through its real setter, so the pending upload debounce
                        // is cancelled and the choice is persisted for that wallet.
                        if newValue, NextcloudService.shared.autoBackupEnabled {
                            NextcloudService.shared.setAutoSyncEnabled(false)
                        }
                    }

                Text("Required for cross-device sync and backup of sent messages.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Automatic sync works with one cloud service at a time.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var nextcloudStoragePage: some View {
        NextcloudSettingsView()
            .navigationTitle("Nextcloud")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var chatHistoryPage: some View {
        Form {
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
                    .disabled(isPreparingChatHistoryExport || restoreCoordinator.isRunning)

                    Button {
                        showChatHistoryImporter = true
                    } label: {
                        HStack {
                            Label("Import Chat History", systemImage: "square.and.arrow.down")
                            Spacer()
                            if restoreCoordinator.isRunning {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPreparingChatHistoryExport || restoreCoordinator.isRunning)
                }
        }
        .navigationTitle("Chat History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnosticsPage: some View {
        DiagnosticsSettingsPage()
    }

    private var dangerZonePage: some View {
        Form {
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
                    .disabled(resyncCoordinator.isRunning)
                    .confirmationDialog(
                        "Wipe and re-sync incoming messages",
                        isPresented: $showWipeIncomingConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("All Chats", role: .destructive) {
                            IncomingResyncCoordinator.shared.start(scope: .all)
                        }
                        Button("Select Chats...") {
                            showResyncChatPicker = true
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes incoming messages locally, then re-syncs them from the blockchain. Your account info and sent messages are preserved. Choose whether to re-sync every chat or only the chats you select.")
                    }
                    .sheet(isPresented: $showResyncChatPicker, onDismiss: {
                        if let selection = pendingResyncSelection {
                            pendingResyncSelection = nil
                            IncomingResyncCoordinator.shared.start(scope: .contacts(selection))
                        }
                    }) {
                        ResyncChatPickerView { addresses in
                            pendingResyncSelection = addresses
                        }
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
                        showWipeICloudConfirmation = true
                    } label: {
                        HStack {
                            Label("Wipe iCloud Data", systemImage: "icloud.slash")
                                .foregroundColor(.red)
                            Spacer()
                            if isWipingICloud {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isWipingICloud)
                    .confirmationDialog(
                        "Wipe iCloud Data",
                        isPresented: $showWipeICloudConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Wipe iCloud Data", role: .destructive) {
                            Task {
                                await wipeICloudData()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This deletes this account's message data from iCloud only. Your local messages and your account stay on this device. If iCloud message storage is enabled, messages may upload to iCloud again over time.")
                    }
                }
        }
        .navigationTitle("Danger Zone")
        .navigationBarTitleDisplayMode(.inline)
    }


    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        // Kaspa logo + bold, matching the balance style on every other screen's top bar.
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text("\(exact) KAS")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
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

    /// iCloud-only wipe: deletes the CURRENT wallet's CloudKit zone and nothing else. Local
    /// messages, contacts, and the account are untouched (the combined local+iCloud wipe this
    /// button used to trigger lives on in `wipeAccountAndMessages`, which the
    /// "Wipe account & messages" entry still uses for the local-only path).
    private func wipeICloudData() async {
        isWipingICloud = true
        defer { isWipingICloud = false }
        if let error = await MessageStore.shared.purgeCurrentWalletCloudKitData() {
            showToast("iCloud wipe failed: \(error.localizedDescription)", style: .error)
        } else {
            showToast("iCloud message data wiped.")
        }
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

    /// Reads the picked archive, then hands it to `BackupRestoreCoordinator`, which runs the
    /// import behind the blocking progress modal (result messaging happens there, not in toasts).
    private func importChatHistoryArchive(result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            showToast("Failed to open archive: \(error.localizedDescription)", style: .error)
        case .success(let fileURL):
            guard !restoreCoordinator.isRunning else { return }

            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: fileURL)
                restoreCoordinator.startLocalRestore(data: data)
            } catch {
                AppLog.log("[Settings] Failed to read chat history archive: %@", error.localizedDescription)
                showToast("Failed to open archive: \(error.localizedDescription)", style: .error)
            }
        }
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

// MARK: - Shared category row (SettingsView + AppSettingsView)

/// The standard Settings category row: icon + title behind a NavigationLink. File-scope so the
/// in-account SettingsView and the accounts-screen AppSettingsView render identical rows.
fileprivate func settingsCategoryRow<Destination: View>(
    _ title: String,
    icon: String,
    tint: Color,
    @ViewBuilder destination: @escaping () -> Destination
) -> some View {
    NavigationLink {
        destination()
    } label: {
        Label {
            Text(title)
                .foregroundColor(tint == .red ? .red : .primary)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(tint)
        }
    }
}

// MARK: - App-wide settings pages (shared by SettingsView and AppSettingsView)
//
// These pages carry the app-wide settings tier - everything here applies to the whole install
// regardless of which account is active, which is why the accounts-list screen's App Settings
// (see AppSettingsView) can host the SAME views without a wallet loaded. The in-account
// SettingsView embeds them unchanged, so there's exactly one source of truth per page.

/// Security page: biometric toggles + Child Mode. All fields live in the global AppSettings
/// blob / device Keychain - nothing here needs an active account, which is exactly why Child
/// Mode is reachable from the accounts list (a parent can manage it without unlocking anything).
struct SecuritySettingsPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Per-ACCOUNT Chats Payment Privacy (moved here from the Chats page). Seeded on appear
    /// from the active account; a no-account context just shows the default.
    @State private var chatsPrivacyEnabled = true

    /// A biometric lock that could be switched off without passing the lock is not a lock -
    /// anyone holding an unlocked phone could have turned all three off and then read the seed
    /// phrase. So the switch itself is gated, in BOTH directions: turning one on is a claim
    /// about who is holding the device too.
    ///
    /// The Toggle is driven off a proxy binding rather than the setting: the write only happens
    /// after authentication succeeds, so a failed or cancelled prompt leaves the switch exactly
    /// where it was instead of flipping and flipping back.
    private func biometricToggle(_ title: String, reason: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { requested in
                guard requested != isOn.wrappedValue else { return }
                DeviceAuth.authenticate(reason: reason) {
                    isOn.wrappedValue = requested
                    settingsViewModel.saveSettings()
                } onFailure: {
                    // Nothing to undo - the setting was never written.
                    Haptics.impact(.medium)
                }
            }
        ))
    }

    var body: some View {
        Form {
            Section("Security") {
                biometricToggle(
                    "Biometrics for Seed Phrase",
                    reason: "Unlock to change the seed phrase biometric lock",
                    isOn: $settingsViewModel.settings.biometricSeedPhraseEnabled
                )
                biometricToggle(
                    "Biometrics for Account Login",
                    reason: "Unlock to change the account login biometric lock",
                    isOn: $settingsViewModel.settings.biometricAccountLoginEnabled
                )
                biometricToggle(
                    "Biometrics for Address Private Keys",
                    reason: "Unlock to change the private key biometric lock",
                    isOn: $settingsViewModel.settings.biometricSpendingKeyEnabled
                )

                NavigationLink {
                    ChildModeSettingsView()
                } label: {
                    HStack {
                        Label {
                            Text("Child Mode")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "figure.and.child.holdinghands")
                                .foregroundColor(.accentColor)
                        }
                        Spacer()
                        Text(settingsViewModel.settings.childModeEnabled ? "On" : "Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Toggle("Chats Payment Privacy", isOn: $chatsPrivacyEnabled)
                    .onChange(of: chatsPrivacyEnabled) { newValue in
                        AppSettings.setChatsPrivacyEnabledForActiveAccount(newValue)
                        // OFF actively revokes our shared pools at every contact holding one
                        // (their next payment falls back to our chatting address immediately);
                        // ON lets the lazy per-contact offers re-fire. See
                        // ChatService+PaymentPools.handleChatsPrivacyToggleChanged.
                        ChatService.shared.handleChatsPrivacyToggleChanged(enabled: newValue)
                    }
            } footer: {
                Text("On: you receive payments on fresh private addresses shared with each contact, and payments you send are funded from your private spending addresses. Off: you receive on your public chatting address and send from it. Either way, payments you send arrive on a fresh address whenever the recipient shares one.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chatsPrivacyEnabled = AppSettings.chatsPrivacyEnabledForActiveAccount()
        }
    }
}

/// The three app-wide customization pickers (Appearance / Language / Currency) as loose rows,
/// so each host wraps them in its own Section: SettingsView's Customization page adds the
/// per-account extras (Customize Dock, Show Setup Guides) after them; AppSettingsView shows
/// them alone.
struct AppWideCustomizationPickers: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
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
        }
    }
}

/// Connection hub: endpoints (indexers/KNS/REST/node) and explorer choice - all global
/// AppSettings fields, safe with no active account.
struct ConnectionHubPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Connection") {
                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    Label("Connection Settings", systemImage: "network")
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
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Diagnostics export, self-contained (own progress/share-sheet/toast state) so it can be
/// hosted from both the in-account Settings and the accounts-screen App Settings. Works with
/// no active account: everything it collects comes from singletons that degrade gracefully
/// (empty conversation list, MessageStore reports zeros when no store is loaded).
struct DiagnosticsSettingsPage: View {
    @State private var isPreparingDiagnostics = false
    @State private var diagnosticsArchiveURL: URL?
    @State private var showDiagnosticsShareSheet = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var verboseAPILogging = AppSettings.load().verboseAPILogging

    var body: some View {
        Form {
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
            Section {
                Toggle("Verbose API Logging", isOn: $verboseAPILogging)
                    .onChange(of: verboseAPILogging) { newValue in
                        var settings = AppSettings.load()
                        guard settings.verboseAPILogging != newValue else { return }
                        settings.verboseAPILogging = newValue
                        AppSettings.save(settings)
                        // AppSettings.save posts .settingsDidChange WITH the settings object,
                        // which the app's long-lived SettingsViewModel deliberately ignores
                        // (it assumes object-bearing posts came from its own saveSettings).
                        // Follow up with a nil-object post - the account-switch signal - so
                        // that instance reloads from disk and its next save can't stomp this
                        // flag with a stale in-memory copy.
                        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                    }
            } footer: {
                Text("Logs every indexer request with full connection and timing detail. Leave off for normal use: failed and slow requests are always logged, and heavy logging can cause iOS to drop the app's log messages.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage, style: toastStyle)
        .sheet(isPresented: $showDiagnosticsShareSheet) {
            if let diagnosticsArchiveURL {
                DiagnosticsShareSheet(fileURL: diagnosticsArchiveURL)
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

// MARK: - App Settings (accounts-list cog)

/// The app-wide settings tier, reachable from the accounts list's gear button when no account
/// is active. Contains ONLY settings that apply to the entire install: Customization
/// (Appearance/Language/Currency - not the per-account dock), Security (including Child Mode -
/// deliberately manageable without unlocking any account), Connection endpoints, and
/// Diagnostics. Everything account-specific (dock, chats, contacts, storage, chat history,
/// notifications, danger zone) intentionally lives only in the in-account SettingsView.
struct AppSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    appCustomizationPage
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    SecuritySettingsPage()
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    ConnectionHubPage()
                }
                settingsCategoryRow("Diagnostics", icon: "stethoscope", tint: .accentColor) {
                    DiagnosticsSettingsPage()
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var appCustomizationPage: some View {
        Form {
            Section("Customization") {
                AppWideCustomizationPickers()
            }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
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

/// Top-level Settings > Notifications hub: a category list (same row style as the main
/// Settings screen) splitting notification prefs by feature - Chats (the pre-existing
/// mode/sound/vibration page, moved here intact from Settings > Chats), Wallet (own-address
/// receive activity), and KaPosts (per-event-type ping toggles).
struct NotificationsHubPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Notifications") {
                settingsCategoryRow("Chats", icon: "bubble.left.and.bubble.right", tint: .accentColor) {
                    NotificationsSettingsView()
                }
                settingsCategoryRow("Wallet", icon: "banknote", tint: .accentColor) {
                    WalletNotificationSettingsView()
                }
                settingsCategoryRow("KaPosts", icon: "square.and.pencil", tint: .accentColor) {
                    KaPostsNotificationSettingsView()
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings > Notifications > Wallet: the own-address receive-activity toggle (see
/// AddressActivityNotifier).
struct WalletNotificationSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Address Activity", isOn: $settingsViewModel.settings.addressActivityNotificationsEnabled)
                    .onChange(of: settingsViewModel.settings.addressActivityNotificationsEnabled) { _ in
                        settingsViewModel.saveSettings()
                    }
            } footer: {
                Text("Notify when any of your spending or cold storage addresses receives Kaspa from an external source. Transfers between your own addresses are ignored.")
            }
        }
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings > Notifications > KaPosts: per-event-type gates for KaPosts pings, mapped from
/// the K notifications API's action kinds (see AppSettings.shouldNotifyKaPostsAction).
/// Disabled types are silently skipped - never queued for later. Orthogonal to Child Mode,
/// which suppresses all KaPosts pings regardless of these.
struct KaPostsNotificationSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Likes", isOn: $settingsViewModel.settings.kaPostsNotifyLikes)
                    .onChange(of: settingsViewModel.settings.kaPostsNotifyLikes) { _ in
                        settingsViewModel.saveSettings()
                        // The extension reads these from the App Group; without this the switch
                        // only ever changed a value nothing downstream could see.
                        SharedDataManager.syncGroupsForExtension()
                    }
                Toggle("Reposts", isOn: $settingsViewModel.settings.kaPostsNotifyReposts)
                    .onChange(of: settingsViewModel.settings.kaPostsNotifyReposts) { _ in
                        settingsViewModel.saveSettings()
                        // The extension reads these from the App Group; without this the switch
                        // only ever changed a value nothing downstream could see.
                        SharedDataManager.syncGroupsForExtension()
                    }
                Toggle("Follows", isOn: $settingsViewModel.settings.kaPostsNotifyFollows)
                    .onChange(of: settingsViewModel.settings.kaPostsNotifyFollows) { _ in
                        settingsViewModel.saveSettings()
                        // The extension reads these from the App Group; without this the switch
                        // only ever changed a value nothing downstream could see.
                        SharedDataManager.syncGroupsForExtension()
                    }
                Toggle("Dislikes", isOn: $settingsViewModel.settings.kaPostsNotifyDislikes)
                    .onChange(of: settingsViewModel.settings.kaPostsNotifyDislikes) { _ in
                        settingsViewModel.saveSettings()
                        // The extension reads these from the App Group; without this the switch
                        // only ever changed a value nothing downstream could see.
                        SharedDataManager.syncGroupsForExtension()
                    }
                Toggle("Comments", isOn: $settingsViewModel.settings.kaPostsNotifyComments)
                    .onChange(of: settingsViewModel.settings.kaPostsNotifyComments) { _ in
                        settingsViewModel.saveSettings()
                        // The extension reads these from the App Group; without this the switch
                        // only ever changed a value nothing downstream could see.
                        SharedDataManager.syncGroupsForExtension()
                    }
            } footer: {
                Text("Choose which KaPosts activity sends a notification. Quotes of your posts count as reposts.")
            }
        }
        .navigationTitle("KaPosts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationsSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var pushManager: PushNotificationManager

    @State private var isEnablingPush = false
    @State private var notificationPermissionDenied = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
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
        .navigationTitle("Chats")
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

    /// Copies sensitive material (the private key hex) to the clipboard with a hard 30s system
    /// expiration and `localOnly` (never syncs to other devices via Universal Clipboard/Handoff).
    /// The system honors `expirationDate` even if the app is suspended before it elapses; the
    /// asyncAfter wipe below is a belt-and-suspenders in-app clear that also fires at 30s when
    /// nothing else has overwritten the clipboard in the meantime.
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
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

    @State private var indexerURL: String = ""
    @State private var kaPostIndexerURL: String = ""
    @State private var translationServiceURL: String = ""
    @State private var broadcastIndexerURL: String = ""
    @State private var pushIndexerURL: String = ""
    @State private var kaspaRestAPIURL: String = ""
    @State private var trustedNodeValidationError: String?

    @State private var newSavedNodeLabel: String = ""
    @State private var newSavedNodeAddress: String = ""
    @State private var savedNodeAddressError: String?

    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    /// Decision 3A: every endpoint field on this page is https-only. Shown inline under any
    /// field whose value starts with http://, and Save refuses to persist while one remains.
    private static let httpsRequiredError = "Use https. Unencrypted connections are not supported."

    /// True when the field value explicitly asks for cleartext http. Bare hostnames (no scheme)
    /// are fine - they are normalized to https:// on save, matching
    /// `NextcloudService.normalizedServerURL`.
    private func isCleartextHTTP(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    /// Inline red caption shown under a URL field while it holds an http:// value.
    @ViewBuilder
    private func httpsInlineError(for value: String) -> some View {
        if isCleartextHTTP(value) {
            Text(Self.httpsRequiredError)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    /// Normalizes a saved endpoint: trims whitespace and defaults a scheme-less value
    /// ("kachat.duckdns.org") to https://, so bare hostnames keep working exactly like the
    /// Nextcloud server field already did. http:// never reaches here - Save rejects it first.
    private func normalizedHTTPSURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased().hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexer URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://kachat.duckdns.org", text: $indexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    httpsInlineError(for: indexerURL)
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
                    httpsInlineError(for: kaPostIndexerURL)
                }
            } header: {
                Text("KaPost Indexer")
            } footer: {
                Text("K social network indexer that powers KaPosts feeds")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translation Service URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(AppSettings.defaultTranslationServiceURL, text: $translationServiceURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    httpsInlineError(for: translationServiceURL)
                }
            } header: {
                Text("Translation Service")
            } footer: {
                Text("Translates KaPosts written in another language. Runs on the KaPost indexer's box by default; point this at your own if you host one (see TRANSLATION_SERVICE.md).")
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
                    httpsInlineError(for: broadcastIndexerURL)
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
                    TextField(AppSettings.defaultPushIndexerURL, text: $pushIndexerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    httpsInlineError(for: pushIndexerURL)
                }
            } header: {
                Text("Push Registration")
            } footer: {
                Text("Used only for push registration and updates")
            }

            Section {
                // Shown, not editable. This field had no empty-string fallback, so saving it
                // blank wrote "" and every KNS call then failed with an unsupported-URL error
                // until it was typed back in. It now follows the selected network.
                VStack(alignment: .leading, spacing: 4) {
                    Text("KNS API URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(settingsViewModel.knsBaseURL)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
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
                    httpsInlineError(for: kaspaRestAPIURL)
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
                        HStack(spacing: 12) {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = entry.address
                                Haptics.success()
                                showToast("Node address copied.")
                            }

                            Button {
                                deleteSavedNodeAddress(entry)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete saved address")
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
                    if saveSettings() {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .toast(message: toastMessage, style: toastStyle)
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

    /// Removes one IP Address Book entry (trash icon on its row). Deliberately does NOT touch
    /// the node selection: deleting the entry for the currently-pinned node keeps the pin (the
    /// picker then shows it as a custom address), matching the existing rule that the picker
    /// always reflects the real connection state - the toast tells the user which case they hit.
    private func deleteSavedNodeAddress(_ entry: SavedNodeAddress) {
        let entryAddress = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.removeAll { $0.id == entry.id }
        settingsViewModel.saveSettings()
        Haptics.success()
        if !pinnedAddress.isEmpty && pinnedAddress == entryAddress {
            showToast("Removed from address book. Still connected to this node.")
        } else {
            showToast("Address removed.")
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
        indexerURL = settingsViewModel.settings.indexerURL
        kaPostIndexerURL = settingsViewModel.settings.kaPostIndexerURL
        translationServiceURL = settingsViewModel.settings.translationServiceURL
        broadcastIndexerURL = settingsViewModel.settings.broadcastIndexerURL
        pushIndexerURL = settingsViewModel.settings.pushIndexerURL
        kaspaRestAPIURL = settingsViewModel.settings.kaspaRestAPIURL
    }

    /// Persists the endpoint fields, or returns false without saving anything when any field
    /// still holds an http:// value (its inline error is already visible; a toast repeats the
    /// reason so the refusal can't be missed). Non-empty scheme-less values are normalized to
    /// A blank field means "use the default", never an empty URL.
    private func normalizedOrDefault(_ value: String, _ fallback: String) -> String {
        let normalized = normalizedHTTPSURL(value)
        return normalized.isEmpty ? fallback : normalized
    }

    /// https:// (Decision 3A).
    @discardableResult
    private func saveSettings() -> Bool {
        let allFields = [indexerURL, kaPostIndexerURL, translationServiceURL, broadcastIndexerURL, pushIndexerURL, kaspaRestAPIURL]
        guard !allFields.contains(where: isCleartextHTTP) else {
            showToast(Self.httpsRequiredError, style: .error)
            return false
        }
        // Every field falls back to its default when left blank. Two of these already did; the
        // rest wrote "" straight through, and an empty base URL builds a scheme-less URL that
        // URLSession rejects with -1002 - which is exactly how the KNS endpoint got wiped, with
        // no error anywhere pointing at the setting that caused it.
        let network = settingsViewModel.settings.networkType
        settingsViewModel.settings.indexerURL = normalizedOrDefault(indexerURL, AppSettings.defaultIndexerURL)
        settingsViewModel.settings.kaPostIndexerURL = normalizedOrDefault(kaPostIndexerURL, AppSettings.defaultKaPostIndexerURL)
        // Blank falls back to the default rather than being written through - an empty base URL
        // builds a request that fails as "unsupported URL" and reads as the server being down,
        // which is exactly how the KNS field broke.
        settingsViewModel.settings.translationServiceURL = normalizedOrDefault(translationServiceURL, AppSettings.defaultTranslationServiceURL)
        settingsViewModel.settings.broadcastIndexerURL = normalizedOrDefault(broadcastIndexerURL, AppSettings.defaultBroadcastIndexerURL)
        settingsViewModel.settings.pushIndexerURL = normalizedOrDefault(pushIndexerURL, AppSettings.defaultPushIndexerURL)
        settingsViewModel.settings.kaspaRestAPIURL = normalizedOrDefault(
            kaspaRestAPIURL,
            AppSettings.defaultKaspaRestURL(for: network)
        )
        settingsViewModel.saveSettings()
        return true
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
    /// Red is reserved for SUSTAINED disconnection. `.disconnected` is also what the status
    /// reads at cold start before the first subscribe and in the gaps between reconnect
    /// attempts, and flashing red there tells the user they're offline when they aren't -
    /// those windows show orange until the state has persisted for the grace period.
    @State private var disconnectedSince: Date?
    @State private var disconnectGraceElapsed = false
    private static let disconnectGrace: TimeInterval = 8

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
            // A full-height sheet, not a detented one: this is a page. It is still an OVERLAY
            // over whatever you were reading rather than a push, so Done puts you back exactly
            // where you were, from any of the fourteen places the dot appears.
            ConnectionStatusDetailView()
        }
        .onAppear { syncDisconnectedAnchor() }
        .onChange(of: chatService.connectionStatus) { _ in syncDisconnectedAnchor() }
        .task(id: disconnectedSince) {
            disconnectGraceElapsed = false
            guard let since = disconnectedSince else { return }
            let remaining = Self.disconnectGrace - Date().timeIntervalSince(since)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if !Task.isCancelled, chatService.connectionStatus == .disconnected {
                disconnectGraceElapsed = true
            }
        }
    }

    private func syncDisconnectedAnchor() {
        if chatService.connectionStatus == .disconnected {
            if disconnectedSince == nil { disconnectedSince = Date() }
        } else {
            disconnectedSince = nil
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
            return disconnectGraceElapsed ? .red : .orange
        }
    }
}

/// Kaspa-logo chatting-address balance for navigation bars - shared by the main pages
/// (KaPosts, Broadcasts, Cold Storage, Portfolio, Swap) so the centered header reads
/// identically across tabs. Chats keeps its own tap-to-copy variant.
struct BalanceToolbarLabel: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text("\(String(format: "%.8f", Double(walletManager.currentWallet?.balanceSompi ?? 0) / 100_000_000.0)) KAS")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .task {
            _ = try? await walletManager.refreshBalance()
        }
    }
}

// MARK: - Connection Status Detail View

struct ConnectionStatusDetailView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @StateObject private var nodePool = NodePoolService.shared
    // Node + latency moved off ChatService to stop 2s ticks re-rendering the whole app;
    // this screen watches them directly so it still updates live.
    @ObservedObject private var nodeInfo = NodeConnectionInfo.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isReconnecting: Bool = false
    @State private var nodeRecords: [NodeRecord] = []
    @State private var showClearPoolConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            // Each section is its own expression. As one Form the body was 330 lines the
            // type checker solved in a single go, and it stopped finishing ("unable to
            // type-check this expression in reasonable time").
            Form {
                statusSection
                poolStatisticsSection
                actionsSection
                KaspaNodeQuickAccessSections(onToast: showToast)
                nodeListSections
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

    /// Status, protocol, and the warnings that qualify them.
    @ViewBuilder
    private var statusSection: some View {
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

            if nodePool.nodeNetworkBlockedSuspected {
                HStack {
                    Text("Node Network")
                    Spacer()
                    Text("Blocked")
                        .foregroundColor(.orange)
                }
                Text("Node connections appear blocked on this network. You can still receive and read messages through the indexer, but sending messages and payments needs a node connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let node = nodeInfo.currentConnectedNode {
                HStack {
                    Text("Connected Node")
                    Spacer()
                    Text(extractHost(from: node))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let latency = nodeInfo.currentNodeLatencyMs {
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
    }

    /// Only meaningful under automatic node selection - see the note inside.
    @ViewBuilder
    private var poolStatisticsSection: some View {

        // Pool Statistics Section - only meaningful under automatic node
        // selection, where the gRPC pool is actually picking nodes. When the
        // user is pinned to the default or a custom node, the registry holds
        // just that one node and pool health/counters are noise, so hide them.
        if isAutomaticNodeSelection {
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
        }
    }

    /// Refresh Pool, Clear Pool, Reconnect.
    @ViewBuilder
    private var actionsSection: some View {
        // Actions Section (pool refresh/clear only apply in automatic mode;
        // Reconnect is useful in every mode)
        Section {
            if isAutomaticNodeSelection {
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
            }

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
    }

    /// Active Nodes and All Nodes, automatic mode only.
    @ViewBuilder
    private var nodeListSections: some View {
        // Node lists only make sense when the pool is discovering nodes;
        // in pinned mode there is nothing here but the pinned node itself.
        if isAutomaticNodeSelection {
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
                        isConnected: record.endpoint.url == nodeInfo.currentConnectedNode
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
    }

    /// True when node selection is Automatic Scan (empty trusted node address), i.e. the
    /// gRPC node pool is actually discovering and picking nodes. A non-empty address
    /// (default recommended node, a saved entry, or free-text custom) pins the app to
    /// that single node via NodeRegistry.setTrustedNode, so pool status is meaningless.
    private var isAutomaticNodeSelection: Bool {
        settingsViewModel.settings.trustedNodeAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
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

/// Settings > Storage > Nextcloud tab: connect/disconnect the user's own Nextcloud server,
/// plus start-folder choice and message backup. Renders bare Sections (no Form of its own) so
/// the Storage page's segmented iCloud/Nextcloud tabs can embed it directly in their Form.
/// Credentials are verified against the OCS user endpoint before being stored in the Keychain
/// (see NextcloudService). The connected account powers the chat attach picker's
/// "From Nextcloud" flow (photos/videos sent as public share links).
struct NextcloudSettingsView: View {
    @ObservedObject private var service = NextcloudService.shared
    // Restore runs on this singleton behind the blocking modal (presented by SettingsView's
    // fullScreenCover, which covers this pushed page too); this view only starts it.
    @ObservedObject private var restoreCoordinator = BackupRestoreCoordinator.shared

    @State private var serverInput = ""
    @State private var usernameInput = ""
    @State private var appPasswordInput = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showDisconnectConfirm = false
    @State private var showStartFolderPicker = false
    @State private var backupInfo: NextcloudFile?
    @State private var isBackingUp = false
    @State private var showRestoreConfirm = false
    @State private var showBackupFolderPicker = false
    @State private var backupStatusMessage: String?
    @State private var backupErrorMessage: String?

    private var canConnect: Bool {
        !serverInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !usernameInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !appPasswordInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !isConnecting
    }

    var body: some View {
        // One concrete container (NOT a Group): presentation modifiers below — .sheet/.alert —
        // must attach to a single view. On a Group they replicate onto every child Section,
        // and the competing presentation attempts pop the whole settings navigation instead
        // of showing the folder picker.
        Form {
            if let account = service.account {
                Section("Connected Account") {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(account.serverURL?.host ?? account.serverURLString)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Text("Username")
                        Spacer()
                        Text(account.username)
                            .foregroundColor(.secondary)
                    }
                }
                Section {
                    Button {
                        showStartFolderPicker = true
                    } label: {
                        HStack {
                            Text("Start Folder")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(account.defaultFolder ?? "All Files")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } footer: {
                    Text("\"Send from Nextcloud\" in chats opens this folder first.")
                }
                Section {
                    Toggle("Send Media via Nextcloud", isOn: $service.mediaSendEnabled)
                } header: {
                    Text("Chat Media")
                } footer: {
                    Text("When on, photos and voice messages you send in private chats upload in full quality to this server's \(NextcloudService.mediaFolderPath) folder, and the chat carries a share link instead — recipients see a normal media bubble. The message with the link stays end-to-end encrypted, but the files themselves are stored unencrypted on your server and are reachable by anyone who has the unguessable link. When off, media is embedded in the encrypted on-chain payload as before.")
                }
                Section {
                    // Custom binding: the setter must go through setAutoSyncEnabled so the
                    // choice is recorded as explicit (see NextcloudService's migration notes).
                    Toggle("Automatic Sync", isOn: Binding(
                        get: { service.autoBackupEnabled },
                        set: { service.setAutoSyncEnabled($0) }
                    ))

                    Text("Automatic sync works with one cloud service at a time.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let lastSynced = service.lastAutoSyncAt {
                        HStack {
                            Text("Last synced")
                            Spacer()
                            Text(lastSynced.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    Button {
                        showBackupFolderPicker = true
                    } label: {
                        HStack {
                            Text("Backup Folder")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(account.backupFolder ?? "\(NextcloudService.backupFolderName) (default)")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }

                    Button {
                        backUpNow()
                    } label: {
                        HStack {
                            Label("Back Up Messages Now", systemImage: "arrow.up.doc")
                            Spacer()
                            if isBackingUp { ProgressView() }
                        }
                    }
                    .disabled(isBackingUp || restoreCoordinator.isRunning)

                    Button {
                        showRestoreConfirm = true
                    } label: {
                        HStack {
                            Label("Restore from Backup", systemImage: "arrow.down.doc")
                            Spacer()
                            if restoreCoordinator.isRunning { ProgressView() }
                        }
                    }
                    .disabled(isBackingUp || restoreCoordinator.isRunning || backupInfo == nil)

                    if let backupInfo, let modified = backupInfo.modified {
                        HStack {
                            Text("Last backup")
                            Spacer()
                            Text("\(modified.formatted(date: .abbreviated, time: .shortened))\(backupInfo.size.map { " · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "")")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    } else if backupInfo == nil {
                        Text("No backup on this server yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let backupStatusMessage {
                        Text(backupStatusMessage)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    if let backupErrorMessage {
                        Text(backupErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Message Backup")
                } footer: {
                    Text("Keeps your chat history in \(NextcloudService.backupFileName) in the folder above (choosing All Files resets to the default \(NextcloudService.backupFolderName) folder). Automatic Sync keeps your devices in near-live sync: new messages upload moments after they arrive, and while the app is open it also watches the server and quietly pulls in what your other devices upload, fastest while you are in a chat. A wallet that connects to an existing backup restores it once automatically. Every upload merges with what is already on the server, so no device can erase another's history. Restoring merges the archive into this device's history.")
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        showDisconnectConfirm = true
                    }
                } footer: {
                    Text("Disconnecting removes the stored app password from this device. Nothing changes on your Nextcloud server.")
                }
            } else {
                Section {
                    TextField("cloud.example.com", text: $serverInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    // Decision 3A: https-only. Bare hostnames are fine (normalizedServerURL
                    // defaults them to https); an explicit http:// is rejected inline here and
                    // again in connect() below.
                    if serverInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                        Text("Use https. Unencrypted connections are not supported.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    TextField("Username", text: $usernameInput)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    RevealableSecureField("App password", text: $appPasswordInput)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Create an app password in Nextcloud under Settings → Security → Devices & sessions — don't use your account password. KaChat stores it in the device Keychain.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                }
            }
        }
        .alert("Disconnect Nextcloud", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                service.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app password is removed from this device's Keychain. You can reconnect any time.")
        }
        .sheet(isPresented: $showStartFolderPicker) {
            NextcloudFolderSelectView { path in
                service.setDefaultFolder(path)
            }
        }
        .sheet(isPresented: $showBackupFolderPicker) {
            NextcloudFolderSelectView { path in
                service.setBackupFolder(path)
                // The backup lives per-folder — re-check what exists at the new destination.
                Task { backupInfo = await NextcloudService.shared.fetchBackupInfo() }
            }
        }
        .alert("Restore from Backup", isPresented: $showRestoreConfirm) {
            Button("Restore") {
                backupStatusMessage = nil
                backupErrorMessage = nil
                // Runs behind the blocking progress modal; the coordinator owns the Task, so
                // nothing this view does (including being popped) can interrupt the restore.
                restoreCoordinator.startNextcloudRestore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages from the server backup are merged into this device's chat history. Nothing is deleted.")
        }
        .task {
            guard service.isConnected else { return }
            backupInfo = await NextcloudService.shared.fetchBackupInfo()
        }
    }

    private func backUpNow() {
        guard !isBackingUp else { return }
        isBackingUp = true
        backupStatusMessage = nil
        backupErrorMessage = nil
        Task {
            do {
                // Merge-on-upload: reads the server's copy first and uploads the union, so a
                // manual backup can never clobber another device's history (or desktop's state).
                try await NextcloudService.shared.runBackup()
                backupInfo = await NextcloudService.shared.fetchBackupInfo()
                backupStatusMessage = "Backup uploaded."
            } catch {
                backupErrorMessage = error.localizedDescription
            }
            isBackingUp = false
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        // Decision 3A: refuse cleartext servers outright instead of attempting a connection.
        if serverInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
            errorMessage = "Use https. Unencrypted connections are not supported."
            return
        }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await NextcloudService.shared.connect(
                    serverInput: serverInput,
                    username: usernameInput,
                    appPassword: appPasswordInput
                )
                appPasswordInput = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

// MARK: - Blocking restore progress modal

/// Full-screen modal shown while a chat-history restore runs (Nextcloud backup download or a
/// locally picked archive). Deliberately inescapable while running: SettingsView presents it via
/// a fullScreenCover whose binding setter is a no-op, interactive dismissal is disabled, and no
/// dismissing control is rendered until the restore reaches a terminal state. Interrupting a
/// restore midway can corrupt local chat state, so the only exits are Done (after success) or
/// Try Again / Close (after failure), all routed through BackupRestoreCoordinator.
struct ChatRestoreProgressModal: View {
    @ObservedObject private var coordinator = BackupRestoreCoordinator.shared

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                switch coordinator.phase {
                case .idle, .running:
                    runningContent
                case .success(let conversations, let messages, let filledSent):
                    successContent(conversations: conversations, messages: messages, filledSent: filledSent)
                case .failure(let message):
                    failureContent(message: message)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(glassBackground(cornerRadius: 24))
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private var runningContent: some View {
        Image(systemName: "arrow.down.doc")
            .font(.system(size: 38, weight: .medium))
            .foregroundColor(.accentColor)

        Text("Restoring Backup")
            .font(.title3.weight(.semibold))

        VStack(spacing: 10) {
            ProgressView(value: coordinator.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.easeInOut(duration: 0.25), value: coordinator.fraction)

            HStack {
                Text(coordinator.stageText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Text("\(Int(coordinator.fraction * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }

        Text("Please keep the app open. Leaving now could corrupt your chat history.")
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func successContent(conversations: Int, messages: Int, filledSent: Int) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 44))
            .foregroundColor(.green)

        Text("Restore Complete")
            .font(.title3.weight(.semibold))

        Text(successMessage(conversations: conversations, messages: messages, filledSent: filledSent))
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

        Button {
            coordinator.dismiss()
        } label: {
            Text("Done")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private func failureContent(message: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 44))
            .foregroundColor(.orange)

        Text("Restore Failed")
            .font(.title3.weight(.semibold))

        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

        VStack(spacing: 10) {
            Button {
                coordinator.retry()
            } label: {
                Text("Try Again")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                coordinator.dismiss()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func successMessage(conversations: Int, messages: Int, filledSent: Int) -> String {
        var text = "Restored \(messages) messages from \(conversations) chats."
        if filledSent > 0 {
            text += " Filled \(filledSent) sent messages."
        }
        return text
    }

    /// Same glass card treatment the app's other overlays use (see BroadcastChannelView).
    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Wipe-and-resync coordinator (blocking progress modal)

/// Owns a Danger Zone incoming-message wipe-and-resync from tap to terminal state, independent
/// of any view's lifetime - the exact ownership pattern of `BackupRestoreCoordinator`.
/// Interrupting the flow between the wipe and the re-fetch would leave chats emptied without
/// their history restored, so the Settings hierarchy only OBSERVES this singleton: the resync
/// `Task` is held here, never by a view, and while `phase == .running` an inescapable
/// fullScreenCover (`IncomingResyncProgressModal`) is presented whose only exits are the
/// modal's own Done / Try Again / Close buttons.
@MainActor
final class IncomingResyncCoordinator: ObservableObject {
    static let shared = IncomingResyncCoordinator()
    private init() {}

    enum Scope: Equatable {
        /// Every known 1:1 chat.
        case all
        /// Only the picked contacts' chats (addresses from the chat picker).
        case contacts([String])
    }

    enum Phase: Equatable {
        case idle
        case running
        case success(chats: Int, messages: Int)
        case failure(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0...1, monotonic. Stage weights mirror the restore modal's pattern: wipe 0-10%,
    /// handshake re-fetch 10-20%, payment re-fetch 20-30%, per-chat contextual re-fetch 30-95%
    /// (the bar advances one chat at a time), finalize 95-100%.
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stageText: String = ""

    var isRunning: Bool { phase == .running }
    var isPresentingModal: Bool { phase != .idle }

    /// Kept so Try Again after a failure reruns the exact same scope (the flow is idempotent:
    /// re-wiping already-wiped chats is a no-op and every fetch dedupes by txId).
    private var lastScope: Scope?
    /// Held by the singleton (not a view) so navigation or sheet churn cannot cancel it.
    private var resyncTask: Task<Void, Never>?

    func start(scope: Scope) {
        guard !isRunning else { return }
        lastScope = scope
        fraction = 0
        stageText = "Preparing..."
        phase = .running
        resyncTask = Task { [weak self] in
            await self?.run(scope)
        }
    }

    /// Reruns the failed resync with the same scope. Only valid from the failure state.
    func retry() {
        guard case .failure = phase, let lastScope else { return }
        phase = .idle
        start(scope: lastScope)
    }

    /// Leaves the modal. Only honored from a terminal state; a running resync cannot be dismissed.
    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
        fraction = 0
        stageText = ""
    }

    private func run(_ scope: Scope) async {
        do {
            let contacts: [String]?
            switch scope {
            case .all:
                contacts = nil
            case .contacts(let picked):
                contacts = picked
            }
            let summary = try await ChatService.shared.wipeAndResyncIncomingMessages(contacts: contacts) { [weak self] event in
                self?.apply(event)
            }
            fraction = 1.0
            stageText = "Done"
            phase = .success(chats: summary.chats, messages: summary.messages)
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    private func apply(_ event: ChatService.IncomingResyncEvent) {
        switch event {
        case .wiping:
            advance(to: 0.05, stage: "Wiping incoming messages...")
        case .fetchingHandshakes:
            advance(to: 0.12, stage: "Re-fetching handshakes...")
        case .fetchingPayments:
            advance(to: 0.22, stage: "Re-fetching payments...")
        case .syncingChats(let done, let total):
            let f = total > 0 ? Double(done) / Double(total) : 1.0
            advance(to: 0.30 + 0.65 * f, stage: "Re-syncing... \(done) of \(total) chats")
        case .finalizing:
            advance(to: 0.96, stage: "Finishing up...")
        }
    }

    /// Monotonic progress: overlapping async reports can never move the bar backwards.
    private func advance(to value: Double, stage: String) {
        fraction = max(fraction, min(value, 1.0))
        stageText = stage
    }
}

// MARK: - Blocking wipe-and-resync progress modal

/// Full-screen modal shown while a Danger Zone wipe-and-resync runs. Deliberately inescapable
/// while running, exactly like `ChatRestoreProgressModal`: presented via a fullScreenCover whose
/// binding setter is a no-op, interactive dismissal disabled, and no dismissing control rendered
/// until a terminal state. Leaving mid-flow would strand chats wiped but not yet re-synced.
struct IncomingResyncProgressModal: View {
    @ObservedObject private var coordinator = IncomingResyncCoordinator.shared

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                switch coordinator.phase {
                case .idle, .running:
                    runningContent
                case .success(let chats, let messages):
                    successContent(chats: chats, messages: messages)
                case .failure(let message):
                    failureContent(message: message)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(glassBackground(cornerRadius: 24))
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private var runningContent: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 38, weight: .medium))
            .foregroundColor(.accentColor)

        Text("Re-syncing Messages")
            .font(.title3.weight(.semibold))

        VStack(spacing: 10) {
            ProgressView(value: coordinator.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.easeInOut(duration: 0.25), value: coordinator.fraction)

            HStack {
                Text(coordinator.stageText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Text("\(Int(coordinator.fraction * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }

        Text("Please keep the app open. Leaving now could leave chats without their history.")
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func successContent(chats: Int, messages: Int) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 44))
            .foregroundColor(.green)

        Text("Re-sync Complete")
            .font(.title3.weight(.semibold))

        Text("Re-synced \(messages) incoming \(messages == 1 ? "message" : "messages") across \(chats) \(chats == 1 ? "chat" : "chats").")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

        Button {
            coordinator.dismiss()
        } label: {
            Text("Done")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private func failureContent(message: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 44))
            .foregroundColor(.orange)

        Text("Re-sync Failed")
            .font(.title3.weight(.semibold))

        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

        VStack(spacing: 10) {
            Button {
                coordinator.retry()
            } label: {
                Text("Try Again")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                coordinator.dismiss()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// Same glass card treatment the app's other overlays use (see BroadcastChannelView).
    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Resync chat picker

/// Multi-select picker for the scoped wipe-and-resync: lists the wallet's 1:1 conversations in
/// chat-list order (group chats live in GroupChatService and are not covered by the incoming
/// wipe, so they are not offered). Hands the picked addresses back via `onConfirm`; the caller
/// starts the resync from the sheet's onDismiss so the blocking modal never races the sheet.
struct ResyncChatPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: ([String]) -> Void

    @State private var conversations: [Conversation] = []
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    Text("No chats to re-sync.")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        Section {
                            ForEach(conversations) { conversation in
                                row(for: conversation)
                            }
                        } footer: {
                            Text("Only the selected chats have their incoming messages wiped and re-synced. Sent messages and all other chats are untouched.")
                        }
                    }
                }
            }
            .navigationTitle("Select Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selected.count == conversations.count ? "Deselect All" : "Select All") {
                        if selected.count == conversations.count {
                            selected = []
                        } else {
                            selected = Set(conversations.map { $0.contact.address })
                        }
                    }
                    .disabled(conversations.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        let picked = Array(selected)
                        onConfirm(picked)
                        dismiss()
                    } label: {
                        Text("Re-sync \(selected.count) \(selected.count == 1 ? "Chat" : "Chats")")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                // Snapshot once: this is a static picker, not a live chat list. Newest activity
                // first, matching the chat list's ordering.
                conversations = ChatService.shared.conversations.sorted { a, b in
                    switch (a.lastMessage?.timestamp, b.lastMessage?.timestamp) {
                    case let (da?, db?):
                        return da > db
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    default:
                        return ContactsManager.shared.displayName(for: a.contact) < ContactsManager.shared.displayName(for: b.contact)
                    }
                }
            }
        }
    }

    private func row(for conversation: Conversation) -> some View {
        let address = conversation.contact.address
        let isSelected = selected.contains(address)
        return Button {
            if isSelected {
                selected.remove(address)
            } else {
                selected.insert(address)
            }
        } label: {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                    fallbackText: ContactsManager.shared.displayName(for: conversation.contact),
                    size: 44,
                    contactAddress: address
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(ContactsManager.shared.displayName(for: conversation.contact))
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Text(address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gift

/// The gift claim, on its own page in Settings. Profile shows the claim row only while there is
/// something to claim; this page is where the gift lives permanently, whatever its state.
///
/// The `.alreadyClaimed` case keeps the hidden 10-tap reset gesture Profile's row used to carry
/// (a support/debug tool) - the button is never `.disabled()`, so the gesture keeps registering
/// even when the claim action itself is a no-op.
struct GiftSettingsPage: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var giftService = GiftService.shared
    @State private var alreadyClaimedTapCount = 0
    @State private var toastMessage: String?

    private var isClaimable: Bool {
        giftService.claimState == .eligible
    }

    private var rowTitle: String {
        switch giftService.claimState {
        case .checking, .eligible: return "Claim Gift"
        case .claiming: return "Claiming gift..."
        case .claimed: return "Gift claimed"
        case .alreadyClaimed: return "Gift already claimed"
        case .unavailable: return "Gift unavailable"
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    switch giftService.claimState {
                    case .eligible:
                        guard let address = walletManager.currentWallet?.publicAddress else { return }
                        Task { await giftService.claimGift(walletAddress: address) }
                    case .alreadyClaimed:
                        alreadyClaimedTapCount += 1
                        guard alreadyClaimedTapCount >= 10 else { return }
                        alreadyClaimedTapCount = 0
                        giftService.resetClaimStateForRetry()
                        Haptics.success()
                        toastMessage = "Gift claim reset. You can request it again."
                    default:
                        break
                    }
                } label: {
                    HStack {
                        Text(rowTitle)
                            .foregroundColor(isClaimable ? .primary : .secondary)
                        Spacer()
                        if giftService.claimState == .claiming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: isClaimable ? "gift.fill" : "gift")
                                .foregroundColor(isClaimable ? .accentColor : .secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                if case .unavailable(let reason) = giftService.claimState {
                    Text(reason)
                        .foregroundColor(.red)
                } else {
                    Text("A one-time gift of Kaspa to get you started, funded to your chatting address.")
                }
            }
        }
        .navigationTitle("Gift")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: giftService.claimState) { _ in
            alreadyClaimedTapCount = 0
        }
        .toast(message: toastMessage, style: .success)
    }
}
