import SwiftUI
import CoreImage
import UIKit

struct ChatInfoView: View {
    @Binding var contact: Contact
    var title: String = "Chat Info"
    /// Per-contact notification overrides only make sense for a 1:1 chat thread - hidden when
    /// viewing a broadcast sender's profile (there's no per-sender notification setting there).
    var showsNotificationSettings: Bool = true
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var contactAvatars = SystemContactAvatarStore.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared

    @State private var editedAlias: String = ""
    @State private var notificationModeOverride: ContactNotificationMode? = nil
    @State private var photoAutoDisplayOverride: PhotoAutoDisplayMode? = nil
    @State private var showAvatarPreview = false
    @State private var moreInfoExpanded = false
    @State private var isBioExpanded = false
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

    /// Describes what "Automatic" currently resolves to for this contact, so the picker
    /// label reflects the smart default (trusted contacts show, untrusted ones hide).
    private var automaticPhotoDisplayDescription: String {
        guard settingsViewModel.settings.requirePhotoApprovalForNewContacts else {
            return "Show"
        }
        return (!contact.isAutoAdded || contact.hasSentOutgoingMessage) ? "Show" : "Hidden"
    }

    private var messages: [ChatMessage] {
        chatService.conversations.first(where: { $0.contact.address == contact.address })?.messages ?? []
    }

    /// nil hides the "Chess Stats" row entirely - only shown once this contact has actually played
    /// at least one chess game (an always-visible "0W - 0L" on every contact who's never played
    /// would just be clutter). See `ChessGameService.record`.
    private var chessRecord: (wins: Int, losses: Int)? {
        guard let myAddress = walletManager.currentWallet?.publicAddress else { return nil }
        let hasChessHistory = messages.contains {
            if case .invite = ChessCodec.parseAny(MessageReplyCodec.unwrappedText($0.content)) { return true }
            return false
        }
        guard hasChessHistory else { return nil }
        return ChessGameService.record(in: messages, myAddress: myAddress, contactAddress: contact.address)
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if KNSProfileLinkBuilder.websiteURL(from: knsProfile?.bannerUrl) != nil {
                        KNSBannerImageView(
                            bannerURLString: knsProfile?.bannerUrl,
                            height: 110,
                            cornerRadius: 10
                        )
                    }

                    HStack {
                        Button {
                            showAvatarPreview = true
                        } label: {
                            KNSAvatarView(
                                avatarURLString: knsProfileInfo?.avatarURL,
                                fallbackText: contact.alias,
                                size: 60,
                                overrideImage: contactAvatars.displayImage(for: contact)
                            )
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $editedAlias)
                                .font(.headline)
                                .focused($isEditing)

                            // Matches Android: the plain contact-name card shows the address as a
                            // fallback caption; once the contact owns any KNS domain, the fancier
                            // profile card below takes over that spot with the bio instead.
                            if knsDomains.isEmpty {
                                Text(formatAddress(contact.address))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else if let bio = knsProfile?.bio {
                                Text(bio)
                                    .font(.subheadline)
                                    .lineLimit(isBioExpanded ? nil : 5)
                                    .onTapGesture {
                                        withAnimation { isBioExpanded.toggle() }
                                    }
                                    .onLongPressGesture(minimumDuration: 0.45) {
                                        copyProfileFieldValue(bio, fieldName: "Bio")
                                    }
                            } else {
                                Text(hasProfileDetailFields ? "On-chain profile data available." : "No on-chain profile data yet.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 8)

                    // Both avatar sources exist (linked Contacts-app photo AND a KNS avatar):
                    // let the user pick which one represents this contact. Contacts photo is
                    // the default; the choice persists per contact.
                    if contactAvatars.rawImage(for: contact) != nil,
                       knsProfileInfo?.avatarURL != nil {
                        Picker("Avatar", selection: Binding(
                            get: { contact.preferKNSAvatar == true },
                            set: { preferKNS in
                                contact.preferKNSAvatar = preferKNS
                                contactsManager.updateContact(contact)
                            }
                        )) {
                            Text("Contacts Photo").tag(false)
                            Text("KNS Avatar").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }

                    if !knsDomains.isEmpty {
                        // Same DisclosureGroup used by the user's own Profile view's KNS card
                        // (ContactsView.knsProfileCard) - native chevron/expand behavior, teal
                        // label, LabeledContent rows with no dividers between them.
                        if hasProfileDetailFields, let profile = knsProfile {
                            DisclosureGroup(isExpanded: $moreInfoExpanded) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let x = profile.x {
                                        LabeledContent("X") {
                                            profileLinkView(text: x, url: KNSProfileLinkBuilder.xURL(from: x), fieldName: "X")
                                        }
                                    }
                                    if let website = profile.website {
                                        LabeledContent("Website") {
                                            profileLinkView(text: website, url: KNSProfileLinkBuilder.websiteURL(from: website), fieldName: "Website")
                                        }
                                    }
                                    if let telegram = profile.telegram {
                                        LabeledContent("Telegram") {
                                            profileLinkView(text: telegram, url: KNSProfileLinkBuilder.telegramURL(from: telegram), fieldName: "Telegram")
                                        }
                                    }
                                    if let discord = profile.discord {
                                        LabeledContent("Discord") {
                                            profileLinkView(text: discord, url: KNSProfileLinkBuilder.discordURL(from: discord), fieldName: "Discord")
                                        }
                                    }
                                    if let contactEmail = profile.contactEmail {
                                        LabeledContent("Email") {
                                            profileLinkView(text: contactEmail, url: KNSProfileLinkBuilder.emailURL(from: contactEmail), fieldName: "Email")
                                        }
                                    }
                                    if let github = profile.github {
                                        LabeledContent("GitHub") {
                                            profileLinkView(text: github, url: KNSProfileLinkBuilder.githubURL(from: github), fieldName: "GitHub")
                                        }
                                    }
                                    if let redirectUrl = profile.redirectUrl {
                                        LabeledContent("Redirect") {
                                            profileLinkView(text: redirectUrl, url: KNSProfileLinkBuilder.websiteURL(from: redirectUrl), fieldName: "Redirect")
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                Text("More Info")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.accentColor)
                            }
                            .tint(.accentColor)
                        }

                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = contact.address
                        Haptics.success()
                        showToast(localized("Address copied to clipboard."))
                    } label: {
                        VStack(spacing: 12) {
                            if let qrImage = makeQRCodeImage(from: contact.address) {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .padding(12)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.accentColor, lineWidth: 2)
                                    )
                            }
                            Text(contact.address)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                } header: {
                    HStack {
                        Text("Address")
                        Spacer()
                        if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: contact.address) {
                            Link("View in Explorer", destination: url)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
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

                if showsNotificationSettings {
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
                }

                Section {
                    Picker("Photos", selection: $photoAutoDisplayOverride) {
                        Text("Automatic (\(automaticPhotoDisplayDescription))")
                            .tag(PhotoAutoDisplayMode?.none)
                        Text("Always Show").tag(PhotoAutoDisplayMode?.some(.alwaysShow))
                        Text("Always Hide").tag(PhotoAutoDisplayMode?.some(.alwaysHide))
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Automatic hides photos from contacts you haven't added or messaged yet, until you tap to reveal them.")
                }

                Section("Info") {
                    LabeledContent("Added") {
                        Text(contact.addedAt, style: .date)
                    }
                    if let lastMessage = contact.lastMessageAt {
                        LabeledContent("Last Message") {
                            if Date().timeIntervalSince(lastMessage) < 86_400 {
                                Text(lastMessage, style: .relative)
                            } else {
                                let days = max(1, Int(Date().timeIntervalSince(lastMessage) / 86_400))
                                Text("\(days) day\(days == 1 ? "" : "s") ago")
                            }
                        }
                    }
                    if let chessRecord {
                        LabeledContent("Chess Stats") {
                            Text("\(chessRecord.wins)W - \(chessRecord.losses)L")
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showAvatarPreview) {
                KNSAvatarFullscreenView(
                    avatarURLString: knsProfileInfo?.avatarURL,
                    fallbackText: contact.alias,
                    title: contact.alias,
                    systemContactId: contact.systemContactId
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
                }
            }
            .onAppear {
                editedAlias = contact.alias
                notificationModeOverride = contact.notificationModeOverride
                photoAutoDisplayOverride = contact.photoAutoDisplayOverride
                linkedSystemContactId = contact.systemContactId
                linkedSystemContactName = contact.systemDisplayNameSnapshot
                linkedSystemContactSource = contact.systemContactLinkSource
            }
            .task {
                // Always force-refresh selected contact KNS info and profile when opening chat info.
                // This ensures profile selection is anchored to the latest primary domain metadata.
                _ = await contactsManager.fetchKNSInfo(for: contact)
                _ = await contactsManager.fetchKNSProfile(for: contact)

                let stats = await MessageStore.shared.messageStats(contactAddress: contact.address)
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
        AppLocalization.string(key)
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }

    private func saveChanges() {
        var updatedContact = contact
        let trimmedAlias = editedAlias.trimmingCharacters(in: .whitespaces)
        updatedContact.alias = trimmedAlias.isEmpty
            ? Contact.generateDefaultAlias(from: contact.address)
            : trimmedAlias
        updatedContact.notificationModeOverride = notificationModeOverride
        updatedContact.photoAutoDisplayOverride = photoAutoDisplayOverride
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
        contactsManager.updateContact(updatedContact)
        contact = updatedContact
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
