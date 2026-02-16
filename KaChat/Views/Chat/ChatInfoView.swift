import SwiftUI
import CoreImage
import UIKit

struct ChatInfoView: View {
    @Binding var contact: Contact
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var editedAlias: String = ""
    @State private var notificationModeOverride: ContactNotificationMode? = nil
    @State private var realtimeUpdatesDisabled: Bool = false
    @State private var isLoadingKNS = false
    @State private var isLoadingBalance = false
    @State private var showQR = false
    @State private var showSystemContactLinkPicker = false
    @State private var linkedSystemContactId: String?
    @State private var linkedSystemContactName: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var messageSent: Int = 0
    @State private var messageReceived: Int = 0
    @FocusState private var isEditing: Bool
    private let qrContext = CIContext()

    private var knsInfo: KNSAddressInfo? {
        contactsManager.getKNSInfo(for: contact)
    }

    private var knsDomains: [KNSDomain] {
        knsInfo?.allDomains ?? []
    }

    private var contactBalanceSompi: UInt64? {
        if let wallet = WalletManager.shared.currentWallet, wallet.publicAddress == contact.address {
            return wallet.balanceSompi
        }
        return contactsManager.balanceSompi(for: contact.address)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.2))
                                .frame(width: 60, height: 60)
                            Text(String(contact.alias.prefix(2)).uppercased())
                                .font(.title2.bold())
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $editedAlias)
                                .font(.headline)
                                .focused($isEditing)
                            Text(formatAddress(contact.address))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Picker("Incoming Notifications", selection: $notificationModeOverride) {
                        Text("Default (\(settingsViewModel.settings.defaultIncomingNotificationMode.displayName))")
                            .tag(ContactNotificationMode?.none)
                        Text("Off").tag(ContactNotificationMode?.some(.off))
                        Text("No Sound").tag(ContactNotificationMode?.some(.noSound))
                        Text("Sound").tag(ContactNotificationMode?.some(.sound))
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Default follows Settings > Notifications. Off disables notifications for this contact.")
                }

                // TODO: Fix realtimeUpdatesDisabled feature - currently broken, hidden until fixed
                // Section {
                //     Toggle(isOn: $realtimeUpdatesDisabled) {
                //         Label("Disable Real-Time Updates", systemImage: realtimeUpdatesDisabled ? "bolt.slash.fill" : "bolt.fill")
                //     }
                // } footer: {
                //     Text("When disabled, messages from this contact will be fetched periodically instead of in real-time. Use this for contacts with high transaction volume to save battery and network usage.")
                // }

                Section("Address") {
                    Button {
                        UIPasteboard.general.string = contact.address
                        Haptics.success()
                        showToast("Address copied to clipboard.")
                    } label: {
                        HStack {
                            Text(contact.address)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.accentColor)
                        }
                    }

                    Button {
                        showQR = true
                    } label: {
                        Label("Show QR", systemImage: "qrcode")
                    }
                }

                Section("Balance") {
                    if isLoadingBalance && contactBalanceSompi == nil {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading balance...")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button {
                            guard let sompi = contactBalanceSompi else { return }
                            UIPasteboard.general.string = formatKaspaExact(sompi)
                            Haptics.success()
                            showToast("Balance copied to clipboard.")
                        } label: {
                            HStack {
                                Text(contactBalanceSompi.map { "\(formatKaspaExact($0)) KAS" } ?? "—")
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .disabled(contactBalanceSompi == nil)
                    }
                }

                Section("System Contact") {
                    if let linkedSystemContactName, !linkedSystemContactName.isEmpty {
                        HStack {
                            Text("Linked")
                            Spacer()
                            Text(linkedSystemContactName)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Not linked")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        showSystemContactLinkPicker = true
                    } label: {
                        Label("Link from Contacts", systemImage: "person.crop.circle.badge.plus")
                    }

                    if linkedSystemContactId != nil {
                        Button(role: .destructive) {
                            contactsManager.unlinkSystemContact(contact)
                            linkedSystemContactId = nil
                            linkedSystemContactName = nil
                            var updatedContact = contact
                            updatedContact.systemContactId = nil
                            updatedContact.systemDisplayNameSnapshot = nil
                            contact = updatedContact
                            showToast("System contact unlinked.")
                        } label: {
                            Label("Unlink", systemImage: "minus.circle")
                        }
                    }
                }

                // KNS Domains section
                if isLoadingKNS {
                    Section("KNS Domains") {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading domains...")
                                .foregroundColor(.secondary)
                        }
                    }
                } else if !knsDomains.isEmpty {
                    Section("KNS Domains") {
                        ForEach(knsDomains, id: \.inscriptionId) { domain in
                            Button {
                                applyDomainAsAlias(domain.fullName)
                            } label: {
                                HStack {
                                    Text(domain.fullName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    if domain.fullName == knsInfo?.primaryDomain {
                                        Spacer()
                                        Text("Primary")
                                            .font(.caption)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Added") {
                        Text(contact.addedAt, style: .date)
                    }
                    if let lastMessage = contact.lastMessageAt {
                        LabeledContent("Last Message") {
                            Text(lastMessage, style: .relative)
                        }
                    }
                    HStack {
                        StatItem(label: "Sent", value: messageSent)
                        Divider().frame(height: 32)
                        StatItem(label: "Received", value: messageReceived)
                        Divider().frame(height: 32)
                        StatItem(label: "Total", value: messageSent + messageReceived)
                    }
                    .padding(.vertical, 4)
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .navigationTitle("Chat Info")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showQR) {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let qrImage = makeQRCodeImage(from: contact.address) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260, maxHeight: 260)
                                .padding(.top, 24)
                        }
                        Text(contact.address)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        Button {
                            UIPasteboard.general.string = contact.address
                            Haptics.success()
                            showToast("Address copied to clipboard.")
                        } label: {
                            Label("Copy Address", systemImage: "doc.on.doc")
                        }
                        .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Share QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showQR = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSystemContactLinkPicker) {
                SystemContactLinkPickerSheet(
                    title: "Link System Contact",
                    onSelect: { target in
                        Task {
                            do {
                                try await contactsManager.linkContactToSystemContact(
                                    contact,
                                    target: target,
                                    updateAlias: false
                                )
                                await MainActor.run {
                                    linkedSystemContactId = target.contactIdentifier
                                    linkedSystemContactName = target.displayName
                                    editedAlias = target.displayName
                                    var updatedContact = contact
                                    updatedContact.systemContactId = target.contactIdentifier
                                    updatedContact.systemDisplayNameSnapshot = target.displayName
                                    updatedContact.alias = target.displayName
                                    contact = updatedContact
                                    showToast("Linked to \(target.displayName).")
                                }
                            } catch {
                                await MainActor.run {
                                    showToast("Failed to link system contact.", style: .error)
                                }
                            }
                        }
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                        dismiss()
                    }
                    .disabled(editedAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                editedAlias = contact.alias
                notificationModeOverride = contact.notificationModeOverride
                realtimeUpdatesDisabled = contact.realtimeUpdatesDisabled
                linkedSystemContactId = contact.systemContactId
                linkedSystemContactName = contact.systemDisplayNameSnapshot
            }
            .task {
                // Fetch KNS info if not already cached
                if knsInfo == nil {
                    isLoadingKNS = true
                    _ = await contactsManager.fetchKNSInfo(for: contact)
                    isLoadingKNS = false
                }
                isLoadingBalance = true
                await contactsManager.refreshBalance(for: contact.address)
                isLoadingBalance = false

                let stats = MessageStore.shared.messageStats(contactAddress: contact.address)
                messageSent = stats.sent
                messageReceived = stats.received
            }
        }
    }

    private func formatAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        let prefix = address.prefix(12)
        let suffix = address.suffix(8)
        return "\(prefix)...\(suffix)"
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

    private func saveChanges() {
        var updatedContact = contact
        let trimmedAlias = editedAlias.trimmingCharacters(in: .whitespaces)
        if !trimmedAlias.isEmpty {
            updatedContact.alias = trimmedAlias
        }
        updatedContact.notificationModeOverride = notificationModeOverride
        updatedContact.systemContactId = linkedSystemContactId
        updatedContact.systemDisplayNameSnapshot = linkedSystemContactName
        // TODO: Fix realtimeUpdatesDisabled feature - currently broken, disabled until fixed
        // let realtimeSettingChanged = updatedContact.realtimeUpdatesDisabled != realtimeUpdatesDisabled
        // updatedContact.realtimeUpdatesDisabled = realtimeUpdatesDisabled
        contactsManager.updateContact(updatedContact)
        contact = updatedContact

        // TODO: Fix realtimeUpdatesDisabled feature - re-enable when fixed
        // Trigger UTXO subscription update if realtime setting changed
        // if realtimeSettingChanged {
        //     Task {
        //         await ChatService.shared.updateUtxoSubscriptionForRealtimeChange()
        //     }
        // }
    }

    private func applyDomainAsAlias(_ domain: String) {
        editedAlias = domain
        Haptics.success()
        showToast("Name set to \(domain). Tap Save to apply.")
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct StatItem: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
