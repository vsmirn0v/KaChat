import SwiftUI
import PhotosUI
import UIKit

struct AddContactView: View {
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var groupChatService: GroupChatService
    @Environment(\.dismiss) private var dismiss

    var onAdd: ((Contact) -> Void)?
    var onCreateGroup: ((GroupChat) -> Void)?

    @State private var addressInput = ""
    @State private var error: String?
    @State private var isValidAddress = false

    // KNS resolution state
    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?
    /// The resolved address's KNS profile, once fetched - the preview card's source.
    @State private var previewProfile: KNSAddressProfileInfo?
    @State private var isLoadingPreview = false
    // KaPosts follow graph, offered as one-tap chat targets under the Address field.
    @State private var pickerContacts: [PickerContact] = []
    /// Starts true so the section renders on first layout and its `.task` actually fires; the
    /// loader clears it, which hides the section entirely when the graph is empty.
    @State private var isLoadingPickerContacts = true
    @State private var didLoadPickerContacts = false
    @State private var isSearchingPickerContacts = false
    @State private var pickerSearchText = ""
    @State private var showQRScanner = false
    @State private var showSystemContactPicker = false
    @State private var pendingSystemContactLinkTarget: SystemContactLinkTarget?

    // Group chat mode
    @State private var isGroupMode = false
    @State private var groupName = ""
    @State private var groupAddressEntries: [GroupAddressEntry] = [GroupAddressEntry()]
    // New group flow: members are picked from existing contacts (searchable), not typed.
    @State private var selectedMemberAddresses: Set<String> = []
    @State private var memberSearchText = ""
    // Group photo picked at creation time. The group does not exist yet, so the compressed JPEG
    // is held here and pushed with `setGroupPhoto` once `createGroup` returns an id.
    @State private var groupPhotoPickerItem: PhotosPickerItem?
    @State private var groupPhotoPreview: UIImage?
    @State private var groupPhotoHex: String?
    @State private var isCreatingGroup = false
    @State private var showCreateGroupConfirm = false
    @State private var scanningGroupRowID: UUID?
    @State private var contactPickerRowID: UUID?
    /// The one member "card" currently expanded for editing (text field + Import/Paste/Scan +
    /// Add Address) - every other entry shows collapsed (name/address + a remove button only).
    /// Tapping a collapsed entry re-expands it; committing the expanded one via "Add Address"
    /// collapses it and expands a fresh blank entry in its place.
    @State private var editingGroupEntryID: UUID?
    private static let maxGroupMembers = 50

    /// One row in the group-member address list - supports both a raw Kaspa address and a KNS
    /// domain (resolved the same way the single-contact flow resolves `addressInput`).
    @MainActor
    private struct GroupAddressEntry: Identifiable {
        let id = UUID()
        var text = ""
        var isResolvingKNS = false
        var resolvedAddress: String?
        var resolvedDomain: String?
        var knsError: String?

        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var looksLikeDomain: Bool { KNSService.looksLikeDomain(trimmedText) }

        /// The actual address this row resolves to (resolved KNS owner address, or the raw
        /// typed/scanned address) - nil while a domain hasn't resolved yet.
        var effectiveAddress: String? {
            looksLikeDomain ? resolvedAddress : (trimmedText.isEmpty ? nil : trimmedText)
        }
    }

    private let knsService = KNSService.shared

    /// The actual address to use (resolved or direct input)
    /// Preview of the person behind the address: their KNS avatar and domain, once resolved.
    ///
    /// Only shown for an address the app is confident about - a half-typed one resolves to
    /// nothing and a card that flickered through wrong faces while typing would be worse than no
    /// card at all.
    @ViewBuilder
    private var contactPreviewCard: some View {
        let address = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, resolvedAddress != nil || isValidAddress {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: previewProfile?.avatarURL,
                    fallbackText: previewProfile?.domainName ?? resolvedDomain ?? address,
                    size: 44,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    // The domain the resolver already found beats waiting on the profile fetch:
                    // if you typed one, that IS the name, and showing it immediately means the
                    // card is useful from the moment the address turns valid.
                    let name = previewProfile?.domainName ?? resolvedDomain
                    Text(name ?? (isLoadingPreview ? "Looking up..." : "No KNS domain"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(name == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(address)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isLoadingPreview { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.top, 4)
            .task(id: address) { await loadPreview(for: address) }
        }
    }

    /// Fetches the resolved address's KNS profile for the card. Cached by KNSService, so
    /// re-typing an address already looked at costs nothing.
    private func loadPreview(for address: String) async {
        guard KaspaAddress.isValid(address) else {
            previewProfile = nil
            return
        }
        if let cached = KNSService.shared.profileCache[address] {
            previewProfile = cached
            return
        }
        isLoadingPreview = true
        previewProfile = await KNSService.shared.fetchProfile(for: address)
        isLoadingPreview = false
    }

    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    init(startInGroupMode: Bool = false, onAdd: ((Contact) -> Void)? = nil, onCreateGroup: ((GroupChat) -> Void)? = nil) {
        self.onAdd = onAdd
        self.onCreateGroup = onCreateGroup
        // The create button is tab-aware (Chats vs Group Chats), so the screen opens
        // directly in the right mode instead of exposing a toggle.
        _isGroupMode = State(initialValue: startInGroupMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isGroupMode {
                    groupChatSections
                } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kaspa Address or KNS Domain")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("kaspa:qr... or name.kas", text: $addressInput)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: addressInput) { newValue in
                                handleInputChange(newValue)
                            }

                        // Show validation status
                        if !addressInput.isEmpty {
                            if isResolvingKNS {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Resolving KNS domain...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if let knsError = knsError {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text(knsError)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            } else if let resolved = resolvedAddress {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Resolved: \(resolvedDomain ?? "")")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                    Text(resolved)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                HStack {
                                    Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(isValidAddress ? .green : .red)
                                    Text(isValidAddress ? "Valid address" : "Invalid address format")
                                        .font(.caption)
                                        .foregroundColor(isValidAddress ? .green : .red)
                                }
                            }

                            // Who you are about to add, as they will appear once added. A raw
                            // address tells you nothing about whether you typed the right one;
                            // a face and a domain do.
                            contactPreviewCard
                        }
                    }

                    HStack {
                        Button {
                            showSystemContactPicker = true
                        } label: {
                            Label("Import", systemImage: "person.crop.circle.badge.plus")
                        }

                        Spacer()

                        Button {
                            if let pastedText = UIPasteboard.general.string {
                                addressInput = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                handleInputChange(addressInput)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }

                        Spacer()

                        Button {
                            showQRScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Enter a Kaspa address (kaspa:...) or KNS domain name (e.g., alice.kas)")
                }

                pickerContactsSection

                if let pendingSystemContactLinkTarget = pendingSystemContactLinkTarget {
                    Section {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(.secondary)
                            Text(pendingSystemContactLinkTarget.displayName)
                        }
                        Button("Clear Link", role: .destructive) {
                            self.pendingSystemContactLinkTarget = nil
                        }
                    } header: {
                        Text("System Contact Link")
                    } footer: {
                        Text("This contact will be linked after it is created. You still need to enter a Kaspa address or KNS domain.")
                    }
                }
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isGroupMode ? "New Group Chat" : "Create chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if isCreatingGroup {
                        ProgressView()
                    } else {
                        Button(isGroupMode ? "Create" : "Add") {
                            if isGroupMode {
                                showCreateGroupConfirm = true
                            } else {
                                addContact()
                            }
                        }
                        .disabled(isGroupMode ? !canCreateGroup : !canAdd)
                    }
                }
            }
            .alert("Create group", isPresented: $showCreateGroupConfirm) {
                Button("Create") { createGroupChat() }
                Button("Cancel", role: .cancel) {}
            } message: {
                let k = selectedMemberAddresses.count
                let txCount = k + 1
                let feeText = groupChatService.estimateGroupActionFeeKas(groupId: "", controlTx: txCount, photoTx: 0)
                    .map { "\n\nEstimated network fee ≈ \($0) KAS across \(txCount) transactions." }
                    ?? "\n\n(\(txCount) network transactions.)"
                Text("Create \"\(groupName.trimmingCharacters(in: .whitespacesAndNewlines))\" and invite \(k) member\(k == 1 ? "" : "s")?\(feeText)")
            }
            .onChange(of: groupPhotoPickerItem) { newItem in
                handleGroupPhotoSelection(newItem)
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { scannedCode in
                    // Handle scanned QR code
                    handleScannedQRCode(scannedCode)
                }
            }
            .sheet(isPresented: Binding(
                get: { scanningGroupRowID != nil },
                set: { isPresented in
                    if !isPresented {
                        scanningGroupRowID = nil
                    }
                }
            )) {
                if let rowID = scanningGroupRowID {
                    QRScannerView { scannedCode in
                        handleScannedGroupQRCode(scannedCode, rowID: rowID)
                        scanningGroupRowID = nil
                    }
                }
            }
            .sheet(isPresented: $showSystemContactPicker) {
                SystemContactPickerSheet(
                    title: "Import from Contacts",
                    onSelect: { selection in
                        switch selection {
                        case .withAddress(let candidate):
                            addressInput = candidate.address
                            resolvedAddress = nil
                            resolvedDomain = nil
                            knsError = nil
                            isResolvingKNS = false
                            isValidAddress = contactsManager.isValidKaspaAddress(candidate.address)
                            pendingSystemContactLinkTarget = nil
                        case .nameOnly(let target):
                            // The link itself carries the address-book name (see
                            // `linkContactToSystemContact`); nothing is prefilled here.
                            pendingSystemContactLinkTarget = target
                        }
                    }
                )
            }
            .sheet(isPresented: Binding(
                get: { contactPickerRowID != nil },
                set: { isPresented in
                    if !isPresented {
                        contactPickerRowID = nil
                    }
                }
            )) {
                if let rowID = contactPickerRowID {
                    SystemContactPickerSheet(
                        title: "Import from Contacts",
                        onSelect: { selection in
                            handleGroupContactSelection(selection, rowID: rowID)
                            contactPickerRowID = nil
                        }
                    )
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        // Strip common prefixes and extract the address
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle kaspa: URI format (kaspa:ADDRESS or kaspa:ADDRESS?amount=X)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            // Check for query parameters and strip them
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }

        addressInput = address
        handleInputChange(address)
    }

    /// Can add if we have a valid address (direct or resolved)
    private var canAdd: Bool {
        if resolvedAddress != nil {
            return true
        }
        return isValidAddress && !isResolvingKNS
    }

    // MARK: - Contacts picker

    /// One person you can start a chat with: someone already in your address book, or someone
    /// from your KaPosts follow graph, or both.
    private struct PickerContact: Identifiable, Equatable {
        let address: String
        let isContact: Bool
        let youFollow: Bool
        let followsYou: Bool
        var id: String { address }

        /// Second line of the row. The follow relationship when there is one, since that is the
        /// thing you would not otherwise know; the address for someone you simply have a chat
        /// with, where the name above it is already the useful part.
        var subtitle: String {
            if youFollow && followsYou { return "You follow each other" }
            if youFollow { return "You follow them" }
            if followsYou { return "Follows you" }
            return Contact.generateDefaultAlias(from: address)
        }
    }

    /// Everyone you could plausibly want to message: your existing chats plus both directions of
    /// your KaPosts follow graph. A chat you had months ago is buried far down the chat list, so
    /// it belongs here next to the people you follow.
    @ViewBuilder
    private var pickerContactsSection: some View {
        if isLoadingPickerContacts || !pickerContacts.isEmpty {
            Section {
                if pickerContacts.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading contacts...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    if isSearchingPickerContacts {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search contacts", text: $pickerSearchText)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                            if !pickerSearchText.isEmpty {
                                Button {
                                    pickerSearchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if filteredPickerContacts.isEmpty {
                        Text("No matches")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredPickerContacts) { connection in
                            Button {
                                addressInput = connection.address
                                handleInputChange(connection.address)
                            } label: {
                                pickerContactRow(connection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Contacts")
                    Spacer()
                    if !pickerContacts.isEmpty {
                        Button {
                            isSearchingPickerContacts.toggle()
                            if !isSearchingPickerContacts { pickerSearchText = "" }
                        } label: {
                            Image(systemName: isSearchingPickerContacts ? "xmark" : "magnifyingglass")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSearchingPickerContacts ? "Close search" : "Search contacts")
                    }
                }
            } footer: {
                Text("Your chats and the people you follow on KaPosts. Tap one to fill in their address.")
            }
            .task { await loadPickerContacts() }
        }
    }

    /// The rows actually shown: everything, or what the search box matches by name or address.
    private var filteredPickerContacts: [PickerContact] {
        let query = pickerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isSearchingPickerContacts, !query.isEmpty else { return pickerContacts }
        return pickerContacts.filter {
            contactsManager.displayName(for: $0.address).lowercased().contains(query)
                || $0.address.lowercased().contains(query)
        }
    }

    private func pickerContactRow(_ connection: PickerContact) -> some View {
        HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[connection.address]?.avatarURL,
                fallbackText: contactsManager.displayName(for: connection.address),
                size: 36,
                contactAddress: connection.address
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(contactsManager.displayName(for: connection.address))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(connection.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines) == connection.address {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())
    }

    /// The address book first, so the list is useful on the first frame, then both follow lists
    /// for our own K identity merged in (along with the locally-stored follows the indexer may
    /// not have caught up on). Only our own address is dropped.
    private func loadPickerContacts() async {
        guard !didLoadPickerContacts else { return }
        didLoadPickerContacts = true

        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        let known = Set(contactsManager.activeContacts.map(\.address)).subtracting([myAddress])
        pickerContacts = sortedPickerContacts(known, known: known, youFollow: [], followsYou: [])
        isLoadingPickerContacts = false

        var youFollow = KaPostsFollowStore.shared.following
        var followsYou: Set<String> = []

        if let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() {
            for wantFollowers in [false, true] {
                var cursor: String?
                var pagesLeft = 5 // 500 accounts per direction, far beyond any real follow list
                while pagesLeft > 0 {
                    pagesLeft -= 1
                    guard let result = try? await KaPostsAPIClient.shared.fetchFollowList(
                        ofPubkey: pubkey, followers: wantFollowers, limit: 100, before: cursor
                    ) else { break }
                    for user in result.users {
                        guard let address = KaPostsAPIClient.kaspaAddress(fromPubkey: user.userPublicKey) else { continue }
                        if wantFollowers {
                            followsYou.insert(address)
                        } else {
                            youFollow.insert(address)
                        }
                    }
                    guard result.pagination?.hasMore == true,
                          let next = result.pagination?.nextCursor else { break }
                    cursor = next
                }
            }
        }

        let addresses = known.union(youFollow).union(followsYou).subtracting([myAddress])

        pickerContacts = sortedPickerContacts(addresses, known: known, youFollow: youFollow, followsYou: followsYou)

        guard !addresses.isEmpty else { return }
        await knsService.refreshProfilesIfNeeded(for: Array(addresses))
        // Re-publish now that domains have landed: the rows name and sort by them.
        pickerContacts = sortedPickerContacts(addresses, known: known, youFollow: youFollow, followsYou: followsYou)
    }

    private func sortedPickerContacts(
        _ addresses: Set<String>,
        known: Set<String>,
        youFollow: Set<String>,
        followsYou: Set<String>
    ) -> [PickerContact] {
        addresses
            .map {
                PickerContact(
                    address: $0,
                    isContact: known.contains($0),
                    youFollow: youFollow.contains($0),
                    followsYou: followsYou.contains($0)
                )
            }
            .sorted {
                contactsManager.displayName(for: $0.address)
                    .localizedCaseInsensitiveCompare(contactsManager.displayName(for: $1.address)) == .orderedAscending
            }
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reset state
        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        // Check if it's a direct Kaspa address
        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            isValidAddress = contactsManager.isValidKaspaAddress(trimmed)
            return
        }

        // Check if it looks like a KNS domain
        if KNSService.looksLikeDomain(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        Task {
            // Add small delay to debounce rapid typing
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

            // Check if input changed during delay
            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            if let resolution = await knsService.resolveDomain(domain) {
                await MainActor.run {
                    resolvedAddress = resolution.ownerAddress
                    resolvedDomain = resolution.domain
                    knsError = nil
                    isResolvingKNS = false

                    // Deliberately does NOT set a name. A contact is only ever named when the
                    // user types one; display falls through to the KNS domain on its own.
                }
            } else {
                await MainActor.run {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    knsError = "KNS domain not found"
                    isResolvingKNS = false
                }
            }
        }
    }

    private func addContact() {
        let addressToUse = effectiveAddress

        do {
            let existedBeforeAdd = contactsManager.getContact(byAddress: addressToUse) != nil
            // No name is stored: `ContactsManager.displayName` shows the KNS domain (then the
            // short address) until the user deliberately renames the contact in Chat Info.
            let contact = try contactsManager.addContact(address: addressToUse, alias: "")

            if !existedBeforeAdd {
                Task {
                    await chatService.syncContactHistoryFromGenesis(contact.address)
                }
            }

            if let pendingSystemContactLinkTarget {
                Task {
                    try? await contactsManager.linkContactToSystemContact(
                        contact,
                        target: pendingSystemContactLinkTarget,
                        updateAlias: false
                    )
                }
            }

            if let onAdd = onAdd {
                onAdd(contact)
            }

            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Group chat mode

    @ViewBuilder
    private var groupChatSections: some View {
        // Photo beside the name, on one row - the two things that identify the group, together.
        Section {
            HStack(spacing: 14) {
                PhotosPicker(selection: $groupPhotoPickerItem, matching: .images) {
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.06))
                        if let image = groupPhotoPreview {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .clipShape(Circle())
                        } else {
                            VStack(spacing: 2) {
                                Image(systemName: "camera")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                                Text("Add\nPhoto")
                                    .font(.system(size: 9))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)

                TextField("Group name", text: $groupName)
                    .font(.headline)
            }
            .padding(.vertical, 6)
        }

        // Add someone who is not in your contacts, by raw address or KNS domain. Reuses the
        // existing resolve / Import / Paste / Scan machinery on a single entry.
        Section {
            ForEach($groupAddressEntries) { $entry in
                VStack(alignment: .leading, spacing: 10) {
                    TextField("kaspa:qr... or name.kas", text: $entry.text)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: entry.text) { newValue in
                            resolveGroupAddress(id: entry.id, input: newValue)
                        }

                    groupAddressStatus(for: entry)

                    Divider()

                    HStack {
                        Button {
                            contactPickerRowID = entry.id
                        } label: {
                            Label("Import", systemImage: "person.crop.circle.badge.plus")
                        }

                        Spacer()

                        Button {
                            if let pastedText = UIPasteboard.general.string {
                                let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                entry.text = trimmed
                                resolveGroupAddress(id: entry.id, input: trimmed)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }

                        Spacer()

                        Button {
                            scanningGroupRowID = entry.id
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .buttonStyle(.borderless)

                    Button {
                        addTypedGroupMember(entry)
                    } label: {
                        Text("Add to Group")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidGroupEntry(entry))
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Add by Address")
        }

        groupMemberPickerSection
    }

    /// Everyone you could add in one tap: your existing chats plus both directions of your
    /// KaPosts follow graph, the same set the create-chat screen offers. Selected people ride
    /// above the list as removable chips so a long list never hides who is already in.
    @ViewBuilder
    private var groupMemberPickerSection: some View {
        Section {
            TextField("Search name or address", text: $memberSearchText)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            if !selectedMemberAddresses.isEmpty {
                GroupMemberChipsRow(
                    addresses: Array(selectedMemberAddresses).sorted {
                        memberDisplayName($0).localizedCaseInsensitiveCompare(memberDisplayName($1)) == .orderedAscending
                    },
                    displayName: memberDisplayName,
                    onRemove: { selectedMemberAddresses.remove($0) }
                )
            }

            if groupCandidates.isEmpty {
                Text(memberSearchText.isEmpty
                     ? "Nobody to suggest yet. Add someone by address above."
                     : "No matches.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(groupCandidates, id: \.self) { address in
                    Button {
                        toggleGroupMember(address)
                    } label: {
                        HStack(spacing: 12) {
                            KNSAvatarView(
                                avatarURLString: knsService.profileCache[address]?.avatarURL,
                                fallbackText: memberDisplayName(address),
                                size: 40,
                                contactAddress: address
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memberDisplayName(address))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(Contact.generateDefaultAlias(from: address))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if selectedMemberAddresses.contains(address) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(selectedMemberAddresses.isEmpty ? "Add People" : "Add People (\(selectedMemberAddresses.count))")
        }
        // The 1:1 screen's loader only runs in its own section, which never renders in group
        // mode - without this the follow graph would be missing here. Guarded internally, so
        // whichever section renders first does the work and the other is a no-op.
        .task { await loadPickerContacts() }
    }

    /// Contacts and the KaPosts follow graph, minus yourself, filtered by the search box.
    /// `pickerContacts` is loaded by the same task the 1:1 screen uses, so this costs nothing extra.
    private var groupCandidates: [String] {
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        var addresses = Set(contactsManager.activeContacts.map(\.address))
        addresses.formUnion(pickerContacts.map(\.address))
        addresses.remove(myAddress)

        let query = memberSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty
            ? addresses
            : addresses.filter {
                memberDisplayName($0).lowercased().contains(query) || $0.lowercased().contains(query)
            }
        return filtered.sorted {
            memberDisplayName($0).localizedCaseInsensitiveCompare(memberDisplayName($1)) == .orderedAscending
        }
    }

    /// Adds a resolved raw-address/KNS entry to the selected members, then resets the field.
    private func addTypedGroupMember(_ entry: GroupAddressEntry) {
        guard isValidGroupEntry(entry), let address = entry.effectiveAddress else { return }
        if selectedMemberAddresses.count < Self.maxGroupMembers {
            selectedMemberAddresses.insert(address)
        }
        groupAddressEntries = [GroupAddressEntry()]
    }

    /// Compresses the picked image to the same ~10KB JPEG budget the admin photo flow uses, and
    /// keeps a preview. Nothing is sent here - the group does not exist yet.
    private func handleGroupPhotoSelection(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        Task {
            defer { Task { @MainActor in groupPhotoPickerItem = nil } }
            guard let data = try? await newItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = try? ImagePrep.prepareJPEGForChatMessage(image, targetBytes: 10_000) else { return }
            await MainActor.run {
                groupPhotoHex = jpeg.hexString
                groupPhotoPreview = UIImage(data: jpeg) ?? image
            }
        }
    }

    /// Display name for a selected member: assigned name -> KNS domain -> short address
    /// (covers members added by raw address / KNS domain).
    private func memberDisplayName(_ address: String) -> String {
        if let contact = contactsManager.activeContacts.first(where: { $0.address == address }) {
            return contactsManager.displayName(for: contact)
        }
        return Contact.generateDefaultAlias(from: address)
    }


    private func toggleGroupMember(_ address: String) {
        if selectedMemberAddresses.contains(address) {
            selectedMemberAddresses.remove(address)
        } else if selectedMemberAddresses.count < Self.maxGroupMembers {
            selectedMemberAddresses.insert(address)
        }
    }

    /// Matches the single-contact flow's `canAdd` trust model exactly: a resolved KNS domain is
    /// trusted outright (the KNS API is the source of truth for it), only a raw typed/scanned/
    /// pasted address gets re-validated here. Re-running a resolved domain's address back through
    /// `isValidKaspaAddress` was the bug behind "KNS domains don't work in group mode" - it isn't
    /// wrong exactly, but it's a stricter, redundant check the 1:1 flow deliberately skips, and it
    /// was silently keeping "Add Address" disabled even after a domain resolved successfully.
    private func isValidGroupEntry(_ entry: GroupAddressEntry) -> Bool {
        if entry.looksLikeDomain {
            return entry.resolvedAddress != nil
        }
        return contactsManager.isValidKaspaAddress(entry.trimmedText)
    }

    /// Lowercased effective addresses that appear more than once across all entries - catches the
    /// same raw address typed twice, the same KNS domain typed twice, and two different KNS
    /// domains that happen to resolve to the same owner address, so the same person can't end up
    /// added to the group twice under a different-looking entry.
    private var duplicateEffectiveAddresses: Set<String> {
        let addresses = groupAddressEntries.compactMap { $0.effectiveAddress?.lowercased() }
        var seen = Set<String>()
        var duplicates = Set<String>()
        for address in addresses {
            if !seen.insert(address).inserted {
                duplicates.insert(address)
            }
        }
        return duplicates
    }

    /// Commits the given entry (must already resolve to a valid address) and opens the next
    /// blank slot for editing, or collapses everything if the member cap is reached.
    private func commitGroupEntry(_ id: UUID) {
        guard let entry = groupAddressEntries.first(where: { $0.id == id }), isValidGroupEntry(entry) else { return }
        if groupAddressEntries.count < Self.maxGroupMembers {
            let newEntry = GroupAddressEntry()
            groupAddressEntries.append(newEntry)
            editingGroupEntryID = newEntry.id
        } else {
            editingGroupEntryID = nil
        }
    }

    /// Switches which entry is expanded - drops the previously-expanded one first if the user
    /// never typed anything into it, rather than leaving a blank collapsed row behind.
    private func setEditingGroupEntry(_ id: UUID) {
        if let currentID = editingGroupEntryID,
           currentID != id,
           let current = groupAddressEntries.first(where: { $0.id == currentID }),
           current.trimmedText.isEmpty,
           groupAddressEntries.count > 1 {
            groupAddressEntries.removeAll { $0.id == currentID }
        }
        editingGroupEntryID = id
    }

    /// Removes an entry outright, always leaving exactly one blank entry available to edit
    /// afterward (unless the member cap is still reached by what remains).
    private func removeGroupEntry(_ id: UUID) {
        let wasEditing = editingGroupEntryID == id
        groupAddressEntries.removeAll { $0.id == id }
        if wasEditing {
            editingGroupEntryID = nil
        }
        if groupAddressEntries.isEmpty || (editingGroupEntryID == nil && groupAddressEntries.count < Self.maxGroupMembers) {
            let newEntry = GroupAddressEntry()
            groupAddressEntries.append(newEntry)
            editingGroupEntryID = newEntry.id
        }
    }

    @ViewBuilder
    private func groupAddressStatus(for entry: GroupAddressEntry) -> some View {
        if entry.trimmedText.isEmpty {
            EmptyView()
        } else if entry.isResolvingKNS {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Resolving KNS domain...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if let knsError = entry.knsError {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(knsError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } else if let effective = entry.effectiveAddress, duplicateEffectiveAddresses.contains(effective.lowercased()) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Already added to this group")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } else if entry.looksLikeDomain, let resolved = entry.resolvedAddress {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Resolved: \(resolved.suffix(12))")
                    .font(.caption)
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
        } else if !entry.looksLikeDomain {
            let isValid = contactsManager.isValidKaspaAddress(entry.trimmedText)
            HStack {
                Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isValid ? .green : .red)
                Text(isValid ? "Valid address" : "Invalid address format")
                    .font(.caption)
                    .foregroundColor(isValid ? .green : .red)
            }
        }
    }

    private func resolveGroupAddress(id: UUID, input: String) {
        guard let index = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        groupAddressEntries[index].resolvedAddress = nil
        groupAddressEntries[index].resolvedDomain = nil
        groupAddressEntries[index].knsError = nil
        groupAddressEntries[index].isResolvingKNS = false

        guard !trimmed.isEmpty, KNSService.looksLikeDomain(trimmed) else { return }

        groupAddressEntries[index].isResolvingKNS = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let currentIndex = groupAddressEntries.firstIndex(where: { $0.id == id }),
                  groupAddressEntries[currentIndex].trimmedText == trimmed else {
                return
            }
            if let resolution = await knsService.resolveDomain(trimmed) {
                await MainActor.run {
                    guard let i = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
                    groupAddressEntries[i].resolvedAddress = resolution.ownerAddress
                    groupAddressEntries[i].resolvedDomain = resolution.domain
                    groupAddressEntries[i].isResolvingKNS = false
                }
            } else {
                await MainActor.run {
                    guard let i = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
                    groupAddressEntries[i].knsError = "KNS domain not found"
                    groupAddressEntries[i].isResolvingKNS = false
                }
            }
        }
    }

    private func handleScannedGroupQRCode(_ code: String, rowID: UUID) {
        var scannedAddress = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if scannedAddress.lowercased().hasPrefix("kaspa:") || scannedAddress.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = scannedAddress.firstIndex(of: "?") {
                scannedAddress = String(scannedAddress[..<queryIndex])
            }
        }
        guard let index = groupAddressEntries.firstIndex(where: { $0.id == rowID }) else { return }
        groupAddressEntries[index].text = scannedAddress
        resolveGroupAddress(id: rowID, input: scannedAddress)
    }

    private func handleGroupContactSelection(_ selection: SystemContactImportSelection, rowID: UUID) {
        guard let index = groupAddressEntries.firstIndex(where: { $0.id == rowID }) else { return }
        switch selection {
        case .withAddress(let candidate):
            groupAddressEntries[index].text = candidate.address
            resolveGroupAddress(id: rowID, input: candidate.address)
        case .nameOnly(let target):
            // No linking-for-later here (unlike the single-contact flow) - a group member needs
            // a real address up front, so just surface why nothing was filled in.
            error = "\(target.displayName) doesn't have a saved Kaspa address."
        }
    }

    private var canCreateGroup: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedMemberAddresses.isEmpty
    }

    private func createGroupChat() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let addresses = Array(selectedMemberAddresses)

        guard !trimmedName.isEmpty else {
            error = "Enter a group name."
            return
        }
        guard !addresses.isEmpty else {
            error = "Add at least one member."
            return
        }

        isCreatingGroup = true
        error = nil

        Task {
            do {
                var members: [Contact] = []
                for address in addresses {
                    if let existing = contactsManager.getContact(byAddress: address) {
                        members.append(existing)
                    } else {
                        members.append(try contactsManager.addContact(address: address, alias: ""))
                    }
                }
                let group = try await groupChatService.createGroup(name: trimmedName, members: members)
                // The photo can only be pushed once the group has an id. Best effort: a failed
                // photo send must not undo a group that was created successfully - the admin can
                // set it again from Group Info.
                if let hex = groupPhotoHex, !hex.isEmpty {
                    try? await groupChatService.setGroupPhoto(group.id, photoHex: hex)
                }
                await MainActor.run {
                    isCreatingGroup = false
                    onCreateGroup?(group)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isCreatingGroup = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    AddContactView()
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(GroupChatService.shared)
}


/// Selected group members as removable chips above the picker list, so a long candidate list
/// never hides who is already in the group.
private struct GroupMemberChipsRow: View {
    let addresses: [String]
    let displayName: (String) -> String
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(addresses, id: \.self) { address in
                    HStack(spacing: 6) {
                        KNSAvatarView(
                            avatarURLString: nil,
                            fallbackText: displayName(address),
                            size: 22,
                            contactAddress: address
                        )
                        Text(displayName(address))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Button {
                            onRemove(address)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            .padding(.vertical, 2)
        }
    }
}
