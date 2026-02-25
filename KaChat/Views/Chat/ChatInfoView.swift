import SwiftUI
import CoreImage
import UIKit

struct ChatInfoView: View {
    @Binding var contact: Contact
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var knsService = KNSService.shared

    @State private var editedAlias: String = ""
    @State private var notificationModeOverride: ContactNotificationMode? = nil
    @State private var realtimeUpdatesDisabled: Bool = false
    @State private var isLoadingKNS = false
    @State private var isLoadingBalance = false
    @State private var showQR = false
    @State private var showAvatarPreview = false
    @State private var showSystemContactLinkPicker = false
    @State private var linkedSystemContactId: String?
    @State private var linkedSystemContactName: String?
    @State private var linkedSystemContactSource: SystemContactLinkSource?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var messageSent: Int = 0
    @State private var messageReceived: Int = 0
    @FocusState private var isEditing: Bool
    private let qrContext = CIContext()

    /// True when the contact is linked to a user-visible system contact (manual or matched), not an auto-created shadow.
    private var hasUserVisibleLink: Bool {
        guard linkedSystemContactId != nil else { return false }
        return linkedSystemContactSource == .manual || linkedSystemContactSource == .matched
    }

    private var knsInfo: KNSAddressInfo? {
        contactsManager.getKNSInfo(for: contact)
    }

    private var knsDomains: [KNSDomain] {
        knsInfo?.allDomains ?? []
    }

    private var knsProfileInfo: KNSAddressProfileInfo? {
        contactsManager.getKNSProfile(for: contact) ?? knsService.profileCache[contact.address]
    }

    private var knsProfile: KNSDomainProfile? {
        knsProfileInfo?.profile
    }

    private var hasProfileDetailFields: Bool {
        guard let profile = knsProfile else { return false }
        return profile.bio != nil
            || profile.x != nil
            || profile.website != nil
            || profile.telegram != nil
            || profile.discord != nil
            || profile.contactEmail != nil
            || profile.github != nil
            || profile.redirectUrl != nil
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
                        Button {
                            showAvatarPreview = true
                        } label: {
                            KNSAvatarView(
                                avatarURLString: knsProfileInfo?.avatarURL,
                                fallbackText: contact.alias,
                                size: 60
                            )
                        }
                        .buttonStyle(.plain)

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

                    if let bannerURL = KNSProfileLinkBuilder.websiteURL(from: knsProfile?.bannerUrl) {
                        AsyncImage(url: bannerURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            case .empty:
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(height: 110)
                                    .overlay {
                                        ProgressView().scaleEffect(0.8)
                                    }
                            case .failure:
                                EmptyView()
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
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
                        showToast(localized("Address copied to clipboard."))
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
                            showToast(localized("Balance copied to clipboard."))
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
                    if hasUserVisibleLink, let linkedSystemContactName, !linkedSystemContactName.isEmpty {
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

                    if hasUserVisibleLink {
                        Button(role: .destructive) {
                            contactsManager.unlinkSystemContact(contact)
                            linkedSystemContactId = nil
                            linkedSystemContactName = nil
                            linkedSystemContactSource = nil
                            var updatedContact = contact
                            updatedContact.systemContactId = nil
                            updatedContact.systemDisplayNameSnapshot = nil
                            updatedContact.systemContactLinkSource = nil
                            contact = updatedContact
                            showToast(localized("System contact unlinked."))
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

                if let profile = knsProfile, hasProfileDetailFields {
                    Section("KNS Profile") {
                        if let bio = profile.bio {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Bio")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(bio)
                                    .font(.body)
                            }
                            .padding(.vertical, 2)
                            .onLongPressGesture(minimumDuration: 0.45) {
                                copyProfileFieldValue(bio, fieldName: "Bio")
                            }
                        }
                        if let x = profile.x {
                            LabeledContent("X") {
                                profileLinkView(
                                    text: x,
                                    url: KNSProfileLinkBuilder.xURL(from: x),
                                    fieldName: "X"
                                )
                            }
                        }
                        if let website = profile.website {
                            LabeledContent("Website") {
                                profileLinkView(
                                    text: website,
                                    url: KNSProfileLinkBuilder.websiteURL(from: website),
                                    fieldName: "Website"
                                )
                            }
                        }
                        if let telegram = profile.telegram {
                            LabeledContent("Telegram") {
                                profileLinkView(
                                    text: telegram,
                                    url: KNSProfileLinkBuilder.telegramURL(from: telegram),
                                    fieldName: "Telegram"
                                )
                            }
                        }
                        if let discord = profile.discord {
                            LabeledContent("Discord") {
                                profileLinkView(
                                    text: discord,
                                    url: KNSProfileLinkBuilder.discordURL(from: discord),
                                    fieldName: "Discord"
                                )
                            }
                        }
                        if let contactEmail = profile.contactEmail {
                            LabeledContent("Email") {
                                profileLinkView(
                                    text: contactEmail,
                                    url: KNSProfileLinkBuilder.emailURL(from: contactEmail),
                                    fieldName: "Email"
                                )
                            }
                        }
                        if let github = profile.github {
                            LabeledContent("GitHub") {
                                profileLinkView(
                                    text: github,
                                    url: KNSProfileLinkBuilder.githubURL(from: github),
                                    fieldName: "GitHub"
                                )
                            }
                        }
                        if let redirectUrl = profile.redirectUrl {
                            LabeledContent("Redirect") {
                                profileLinkView(
                                    text: redirectUrl,
                                    url: KNSProfileLinkBuilder.websiteURL(from: redirectUrl),
                                    fieldName: "Redirect"
                                )
                            }
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
                        StatItem(label: String(localized: "Sent"), value: messageSent)
                        Divider().frame(height: 32)
                        StatItem(label: String(localized: "Received"), value: messageReceived)
                        Divider().frame(height: 32)
                        StatItem(label: String(localized: "Total"), value: messageSent + messageReceived)
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
                            showToast(localized("Address copied to clipboard."))
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
            .fullScreenCover(isPresented: $showAvatarPreview) {
                KNSAvatarFullscreenView(
                    avatarURLString: knsProfileInfo?.avatarURL,
                    fallbackText: contact.alias,
                    title: contact.alias
                )
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
                                    linkedSystemContactSource = .manual
                                    editedAlias = target.displayName
                                    var updatedContact = contact
                                    updatedContact.systemContactId = target.contactIdentifier
                                    updatedContact.systemDisplayNameSnapshot = target.displayName
                                    updatedContact.systemContactLinkSource = .manual
                                    updatedContact.alias = target.displayName
                                    contact = updatedContact
                                    showToast(localizedFormat("Linked to %@.", target.displayName))
                                }
                            } catch {
                                await MainActor.run {
                                    showToast(localized("Failed to link system contact."), style: .error)
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
                linkedSystemContactSource = contact.systemContactLinkSource
            }
            .task {
                // Fetch KNS domains/profile if not already cached
                if knsInfo == nil || knsProfileInfo == nil {
                    isLoadingKNS = true
                    _ = await contactsManager.fetchKNSInfo(for: contact)
                    _ = await contactsManager.fetchKNSProfile(for: contact)
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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
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
        updatedContact.systemContactLinkSource = linkedSystemContactSource
        if !settingsViewModel.settings.autoCreateSystemContacts,
           updatedContact.systemContactLinkSource == .autoCreated {
            updatedContact.systemContactId = nil
            updatedContact.systemDisplayNameSnapshot = nil
            updatedContact.systemContactLinkSource = nil
            updatedContact.systemMatchConfidence = nil
        }
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
        showToast(localizedFormat("Name set to %@. Tap Save to apply.", domain))
    }

    @ViewBuilder
    private func profileLinkView(text: String, url: URL?, fieldName: String) -> some View {
        if let url {
            Link(text, destination: url)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        copyProfileFieldValue(text, fieldName: fieldName)
                    }
                )
        } else {
            Text(text)
                .foregroundColor(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    copyProfileFieldValue(text, fieldName: fieldName)
                }
        }
    }

    private func copyProfileFieldValue(_ value: String, fieldName: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        showToast(localizedFormat("%@ copied to clipboard.", fieldName))
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
