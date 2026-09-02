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
    /// Revealed values for the Aliases section's rows (nil while hidden behind dots).
    @State private var revealedReceivingAlias: String?
    @State private var revealedSendingAlias: String?

    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var contactAvatars = SystemContactAvatarStore.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared

    @State private var editedAlias: String = ""
    @State private var notificationModeOverride: ContactNotificationMode? = nil
    /// Which section's half sheet is up.
    @State private var activeSheet: InfoSheet?

    private enum InfoSheet: String, Identifiable {
        case address, domains, aliases, systemContact, notifications, photos, info
        var id: String { rawValue }
    }
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
    /// False only until the KNS address-info lookup for this contact has come back at least
    /// once (seeded true in `onAppear` when the cache already has an entry, so a revisit shows
    /// the list straight away instead of flashing a spinner). Purely cosmetic - the Domains
    /// section never blocks the rest of the Form on it.
    @State private var knsDomainsLoaded = false
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

    /// Bare, lowercased domain key (".kas" stripped) - `/primary-name` and `/assets` don't
    /// agree on whether the suffix is present, so compare without it.
    private func normalizedDomainKey(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix(".kas") ? String(trimmed.dropLast(4)) : trimmed
    }

    /// Which domain gets the "Primary" badge. Prefers the inscription id KNS returns with the
    /// reverse lookup (an exact on-chain asset id), and falls back to name matching.
    /// `explicitPrimaryDomain` is the real `/primary-name` answer; when the contact never set a
    /// primary it's nil and KNS falls back to `allDomains.first` for `primaryDomain` (see
    /// `KNSAddressInfo`). We badge that fallback too, since it is the name the rest of the app
    /// already shows for this contact, and the section footer says which case applies.
    private func isPrimaryDomain(_ domain: KNSDomain) -> Bool {
        guard let info = knsInfo else { return false }
        if let inscriptionId = info.primaryInscriptionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inscriptionId.isEmpty {
            return domain.inscriptionId == inscriptionId
        }
        guard let primaryKey = normalizedDomainKey(info.explicitPrimaryDomain ?? info.primaryDomain) else {
            return false
        }
        return normalizedDomainKey(domain.fullName) == primaryKey
    }

    /// True when the badged primary came from an explicit reverse lookup rather than the
    /// "first domain owned" fallback.
    private var hasExplicitPrimaryDomain: Bool {
        guard let explicit = knsInfo?.explicitPrimaryDomain?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !explicit.isEmpty
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
                                contactAddress: contact.address
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
                    // let the user pick which one represents this contact. The KNS avatar is the
                    // default (see SystemContactAvatarStore's resolution order); the choice
                    // persists per contact.
                    if contactAvatars.rawImage(for: contact) != nil,
                       knsProfileInfo?.avatarURL != nil {
                        Picker("Avatar", selection: Binding(
                            get: { contact.preferKNSAvatar ?? true },
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
                    // Each section is a card that opens a half sheet. The form had grown to
                    // seven stacked sections - a QR, a domain list, alias reveals, system
                    // contact linking, two pickers and a stats block - which is a lot of screen
                    // to scroll past to reach any one of them.
                    infoCard(
                        "Address",
                        systemImage: "qrcode"
                    ) { activeSheet = .address }

                    infoCard(
                        "KNS Domains",
                        systemImage: "at"
                    ) { activeSheet = .domains }
                    .disabled(knsDomains.isEmpty)

                    infoCard(
                        "Aliases",
                        systemImage: "number"
                    ) { activeSheet = .aliases }

                    infoCard(
                        "System Contact",
                        systemImage: "person.crop.circle"
                    ) { activeSheet = .systemContact }

                    if showsNotificationSettings {
                        infoCard(
                            "Notifications",
                            systemImage: notificationModeOverride == .off ? "bell.slash" : "bell"
                        ) { activeSheet = .notifications }
                    }

                    infoCard(
                        "Photos",
                        systemImage: "photo"
                    ) { activeSheet = .photos }

                    infoCard(
                        "Info",
                        systemImage: "info.circle"
                    ) { activeSheet = .info }
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .address: addressSheet
                case .domains: domainsSheet
                case .aliases: aliasesSheet
                case .systemContact: systemContactSheet
                case .notifications: notificationsSheet
                case .photos: photosSheet
                case .info: infoSheet
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showAvatarPreview) {
                KNSAvatarFullscreenView(
                    avatarURLString: knsProfileInfo?.avatarURL,
                    fallbackText: contact.alias,
                    title: contact.alias,
                    systemContactId: contact.systemContactId,
                    contactAddress: contact.address
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
                // Already cached? Show the domains immediately rather than a spinner.
                if knsInfo != nil { knsDomainsLoaded = true }
            }
            .task {
                // Always force-refresh selected contact KNS info and profile when opening chat info.
                // This ensures profile selection is anchored to the latest primary domain metadata.
                _ = await contactsManager.fetchKNSInfo(for: contact)
                // The Domains section stops showing its loading row once the lookup has
                // answered, whether or not it found anything.
                knsDomainsLoaded = true
                _ = await contactsManager.fetchKNSProfile(for: contact)

                let stats = await MessageStore.shared.messageStats(contactAddress: contact.address)
                messageSent = stats.sent
                messageReceived = stats.received
            }
        }
    }

    /// Primary first, then the rest alphabetically - a stable order that doesn't jump around as
    /// the cache refreshes. Keyed by `inscriptionId` via `KNSDomain: Identifiable`.
    private var sortedKNSDomains: [KNSDomain] {
        knsDomains.sorted { lhs, rhs in
            let lhsIsPrimary = isPrimaryDomain(lhs)
            let rhsIsPrimary = isPrimaryDomain(rhs)
            if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
            return lhs.fullName.lowercased() < rhs.fullName.lowercased()
        }
    }

    /// One domain row: name, a Primary badge on the contact's primary, and a verified check.
    /// Tapping copies the full domain, matching the copy-on-tap idiom the Address and Aliases
    /// sections already use.

    private func formatAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        let prefix = address.prefix(12)
        let suffix = address.suffix(8)
        return "\(prefix)...\(suffix)"
    }

    /// One reveal-then-copy alias row: dots + eye while hidden, first tap derives and reveals
    /// the monospaced value, tapping the revealed value copies it with the standard toast.
    private var addressSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        UIPasteboard.general.string = contact.address
                        Haptics.success()
                        showToast(contact.address.addressCopiedToastText)
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
            }
            .navigationTitle("Address")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The list itself, not a row that opens it. Data comes from the same KNSService address-info
    /// cache the rest of the screen reads, so this costs no fetch.
    private var domainsSheet: some View {
        NavigationStack {
            ContactDomainsView(
                domains: sortedKNSDomains,
                isPrimary: isPrimaryDomain,
                hasExplicitPrimary: hasExplicitPrimaryDomain,
                onCopy: { copyProfileFieldValue($0, fieldName: "Domain") }
            )
            .navigationTitle("KNS Domains")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var aliasesSheet: some View {
        NavigationStack {
            Form {
                // This conversation's deterministic pair aliases (DeterministicAlias, ECDH +
                // HKDF, 12 hex chars). Direction semantics match ChatService's routing state:
                // deriveMyAlias = deterministicMyAlias = incoming/watch (the alias messages
                // FROM this contact carry, what we watch for), deriveTheirAlias =
                // deterministicTheirAlias = outgoing/send (the alias OUR messages to them
                // carry). Hidden behind dots until tapped; keys are only touched on demand.
                Section {
                    aliasRow("Receiving alias", value: $revealedReceivingAlias) {
                        guard let key = walletManager.getPrivateKey() else { return nil }
                        return try? DeterministicAlias.deriveMyAlias(privateKey: key, theirAddress: contact.address)
                    }
                    aliasRow("Sending alias", value: $revealedSendingAlias) {
                        guard let key = walletManager.getPrivateKey() else { return nil }
                        return try? DeterministicAlias.deriveTheirAlias(privateKey: key, theirAddress: contact.address)
                    }
                } header: {
                    Text("Aliases")
                } footer: {
                    Text("These identify this conversation's messages on the network. Receiving is the alias on messages this contact sends you. Sending is the alias on messages you send them. Useful when building tools that message this chat.")
                }
            }
            .navigationTitle("Aliases")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var systemContactSheet: some View {
        NavigationStack {
            Form {
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

                    if contact.systemContactId == nil {
                        // Replaces the old "autocreate" setting: one tap creates a dedicated
                        // entry in the iOS Contacts app for this contact and links it.
                        Button {
                            Task {
                                if let updated = await contactsManager.createSystemContact(for: contact) {
                                    contact = updated
                                    linkedSystemContactId = updated.systemContactId
                                    linkedSystemContactName = updated.systemDisplayNameSnapshot
                                    linkedSystemContactSource = updated.systemContactLinkSource
                                    showToast(localized("Contact created in Contacts app."))
                                } else {
                                    showToast(localized("Couldn't create the contact. Check Contacts access."))
                                }
                            }
                        } label: {
                            Label("Create System Contact", systemImage: "person.badge.plus")
                        }
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
            }
            .navigationTitle("System Contact")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var notificationsSheet: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var photosSheet: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var infoSheet: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    /// One section, as a row that opens its half sheet. Title only - the contents belong in the
    /// sheet, and a trailing value on every row turned the list back into the dense screen the
    /// cards were meant to replace.
    private func infoCard(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 26)
                Text(title)
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aliasRow(
        _ title: LocalizedStringKey,
        value: Binding<String?>,
        derive: @escaping () -> String?
    ) -> some View {
        Button {
            if let revealed = value.wrappedValue {
                UIPasteboard.general.string = revealed
                Haptics.success()
                showToast(localized("Alias copied to clipboard."))
            } else if let derived = derive() {
                value.wrappedValue = derived
            } else {
                showToast(localized("Alias unavailable."), style: .error)
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if let revealed = value.wrappedValue {
                    Text(revealed)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(String(repeating: "\u{2022}", count: 12))
                            .foregroundColor(.secondary)
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// The contact's KNS domains, primary first, on their own screen.
///
/// Pushed from Chat Info rather than listed inline: an address owning a few dozen domains buried
/// everything below it in that form. The rows are handed in already sorted and already resolved,
/// so this view does no lookups of its own and shows whatever Chat Info had cached.
private struct ContactDomainsView: View {
    let domains: [KNSDomain]
    let isPrimary: (KNSDomain) -> Bool
    /// True when the badged primary came from an explicit reverse lookup rather than the
    /// "first domain owned" fallback - the footer says which, so a wrong-looking badge is
    /// explainable rather than mysterious.
    let hasExplicitPrimary: Bool
    let onCopy: (String) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(domains) { domain in
                    row(domain)
                }
            } footer: {
                if hasExplicitPrimary {
                    Text("Primary is the domain this contact set as their KNS primary name. Tap any domain to copy it.")
                } else {
                    Text("This contact hasn't set a KNS primary name, so their first domain is used as the primary. Tap any domain to copy it.")
                }
            }
        }
        .navigationTitle("Domains")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ domain: KNSDomain) -> some View {
        let primary = isPrimary(domain)
        return Button {
            onCopy(domain.fullName)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: primary ? "star.fill" : "at")
                    .font(.caption)
                    .foregroundColor(primary ? .accentColor : .secondary)
                    .frame(width: 18)

                Text(domain.fullName)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if domain.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .accessibilityLabel(Text("Verified"))
                }

                Spacer(minLength: 8)

                if primary {
                    Text("PRIMARY")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
