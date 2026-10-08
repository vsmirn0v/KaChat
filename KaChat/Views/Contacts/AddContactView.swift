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
    /// When set (inside the Chats New sheet), Cancel goes back to that sheet's menu instead of
    /// closing it.
    var onCancel: (() -> Void)?

    @State private var addressInput = ""
    /// Start this chat as Private (no inbox tag ever) - see the toggle's footer.
    @State private var startPrivate = false
    @State private var error: String?
    @State private var isValidAddress = false

    // KNS resolution state
    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?
    /// What the typed name points to on every name service (.kachat first), and which one the
    /// chat will use - the priority answer until a different one is picked under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedResolutionTLD: NameServiceTLD?
    @State private var showOtherDomains = false
    /// The resolved address's KNS profile, once fetched - the preview card's source.
    @State private var previewProfile: KNSAddressProfileInfo?
    @State private var isLoadingPreview = false
    @State private var showQRScanner = false
    @State private var showAddressBookPicker = false

    // Group chat mode
    @State private var isGroupMode = false
    @State private var groupName = ""
    @State private var groupAddressEntries: [GroupAddressEntry] = [GroupAddressEntry()]
    // New group flow: members are picked from existing contacts (searchable), not typed.
    @State private var selectedMemberAddresses: Set<String> = []
    @State private var membersExpanded = false
    /// The group's Address Book: a full-screen multi-select of saved addresses.
    @State private var showGroupAddressBook = false
    // Group photo picked at creation time. The group does not exist yet, so the compressed JPEG
    // is held here and pushed with `setGroupPhoto` once `createGroup` returns an id.
    @State private var groupPhotoPickerItem: PhotosPickerItem?
    @State private var groupPhotoPreview: UIImage?
    @State private var groupPhotoHex: String?
    @State private var isCreatingGroup = false
    @State private var showCreateGroupConfirm = false
    @State private var scanningGroupRowID: UUID?
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
        var looksLikeDomain: Bool { NameServicesClient.looksLikeName(trimmedText) }

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
                    Text(name ?? (isLoadingPreview ? "Looking up..." : "No domain"))
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

    init(startInGroupMode: Bool = false, onAdd: ((Contact) -> Void)? = nil, onCreateGroup: ((GroupChat) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.onAdd = onAdd
        self.onCreateGroup = onCreateGroup
        self.onCancel = onCancel
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
                        Text("Kaspa Address or Domain")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("kaspa:qr... or domain", text: $addressInput)
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
                                    Text("Looking up domain...")
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
                                otherDomainsDropdown
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
                                otherDomainsDropdown
                            } else {
                                HStack {
                                    Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(isValidAddress ? .green : .red)
                                    Text(verbatim: KaspaAddress.validityText(addressInput, isValid: isValidAddress))
                                        .font(.caption)
                                        .foregroundColor(isValidAddress ? .green : .red)
                                }
                            }

                            // Who you are about to add, as they will appear once added. A raw
                            // address tells you nothing about whether you typed the right one;
                            // a face and a domain do.
                            contactPreviewCard
                        }

                        // Why Add refused, right under the field that caused it. The same text
                        // used to sit in a section at the very bottom of the form - below the
                        // contacts picker, under the keyboard - where a refused add looked like
                        // a tap that did nothing.
                        if let error, !isGroupMode {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    HStack {
                        Button {
                            showAddressBookPicker = true
                        } label: {
                            Label("Address Book", systemImage: "book.closed")
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

                // Private: no first-contact signal at all (NO_HANDSHAKE_MESSAGING.md §3.1).
                Section {
                    Toggle(isOn: $startPrivate) {
                        Label("Private Chat", systemImage: "lock.fill")
                    }
                } footer: {
                    Text(startPrivate
                         ? "Nothing on chain links you two - not even who wrote first. They won't be notified: they'll see your messages once they start a private chat with your address too, so agree on it somewhere else first."
                         : "They'll get your first message as a Message Request. Turn on Private Chat if you'd rather leave no link between you on chain.")
                }

                }

                if let error, isGroupMode {
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
                        if let onCancel { onCancel() } else { dismiss() }
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
                    .map { "\n\nEstimated network fee ≈ \($0) \(KaspaUnit.symbol) across \(txCount) transactions." }
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
            .fullScreenCover(isPresented: $showAddressBookPicker) {
                AddressBookPickerSheet { entry in
                    addressInput = entry.address
                    resolvedAddress = nil
                    resolvedDomain = nil
                    knsError = nil
                    isResolvingKNS = false
                    isValidAddress = contactsManager.isValidKaspaAddress(entry.address)
                }
            }
            .fullScreenCover(isPresented: $showGroupAddressBook) {
                // Ticks show who is already in; the result replaces the Address Book part of the
                // roster, so unticking someone takes them out again.
                AddressBookPickerSheet(
                    preselected: selectedMemberAddresses,
                    excluding: WalletManager.shared.currentWallet?.publicAddress
                ) { picked in
                    let bookAddresses = Set(AddressBookManager.shared.entries.map { AddressBookManager.normalize($0.address) })
                    var members = selectedMemberAddresses.filter { !bookAddresses.contains(AddressBookManager.normalize($0)) }
                    for address in picked.map(\.address) where members.count < Self.maxGroupMembers {
                        members.insert(address)
                    }
                    selectedMemberAddresses = members
                    if !members.isEmpty { membersExpanded = true }
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

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reset state
        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        error = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedResolutionTLD = nil
        showOtherDomains = false

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        // Check if it's a direct Kaspa address
        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            // the other network's address is the same key on another chain: refused
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        // A name on any service - .kachat, .kas, .k, .kaspa - typed with or without its ending.
        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveName(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Looks the name up on every service at once. The chat goes to the priority answer - the
    /// ending the person typed, else .kachat, then .kas, .k, .kaspa - and the others are listed
    /// under "Other domains" to pick instead.
    private func resolveName(_ typed: String) {
        isResolvingKNS = true

        Task {
            // Debounce rapid typing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == typed else { return }

            let results = await NameServicesClient.shared.resolveEverywhere(typed)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == typed else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let primary = NameServicesClient.primary(of: results, typed: typed) {
                    applyResolution(primary)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    // Deliberately does NOT set a name. A contact is only ever named when the
                    // user types one; display falls through to the domain on its own.
                    let explicit = NameServiceTLD.splitTypedName(typed).tld
                    knsError = explicit.map { String(localized: "No \($0.suffix) domain found") } ?? String(localized: "No domain found")
                    // Nothing resolved for the ending typed, but another service may have it.
                    showOtherDomains = results.contains { $0.address != nil }
                }
            }
        }
    }

    private func applyResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        selectedResolutionTLD = resolution.tld
        resolvedAddress = address
        resolvedDomain = resolution.display
        knsError = nil
    }

    /// "Other domains": what the same name points to on the other services, each selectable.
    @ViewBuilder
    private var otherDomainsDropdown: some View {
        let others = nameResolutions.filter { $0.tld != selectedResolutionTLD }
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $showOtherDomains) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others) { resolution in
                        Button {
                            applyResolution(resolution)
                            showOtherDomains = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resolution.display)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(resolution.address == nil ? .secondary : .primary)
                                    Text(resolution.address
                                         ?? (resolution.failed ? String(localized: "Couldn't check") : String(localized: "Not registered")))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if resolution.address != nil {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolution.address == nil)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Other domains")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .tint(.accentColor)
        }
    }

    private func addContact() {
        let addressToUse = effectiveAddress

        do {
            let existedBeforeAdd = contactsManager.getContact(byAddress: addressToUse) != nil
            // No name is stored: `ContactsManager.displayName` shows the KNS domain (then the
            // short address) until the user deliberately renames the contact in Chat Info.
            let contact = try contactsManager.addContact(address: addressToUse, alias: "")
            // Starting a chat accepts it; Private also keeps it from ever carrying the inbox tag.
            if startPrivate {
                chatService.setPrivateChat(contact.address, true)
            } else {
                chatService.acceptChat(contact.address)
            }

            if !existedBeforeAdd {
                Task {
                    await chatService.syncContactHistoryFromGenesis(contact.address)
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
                                    .font(.scaled(size: 16))
                                    .foregroundColor(.secondary)
                                Text("Add\nPhoto")
                                    .font(.scaled(size: 9))
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

        groupMemberPickerSection

        // How members are added: several at once from the Address Book, or anyone by address,
        // domain, paste or QR on a single entry.
        Section {
            ForEach($groupAddressEntries) { $entry in
                VStack(alignment: .leading, spacing: 10) {
                    TextField("kaspa:qr... or domain", text: $entry.text)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: entry.text) { newValue in
                            resolveGroupAddress(id: entry.id, input: newValue)
                        }

                    groupAddressStatus(for: entry)

                    // Who you are about to add, as they will appear once added - the same card
                    // the 1:1 create-chat screen shows. A raw address tells you nothing about
                    // whether you typed the right one; a face and a domain do.
                    groupAddressPreviewCard(for: entry)

                    Divider()

                    HStack {
                        Button {
                            showGroupAddressBook = true
                        } label: {
                            Label("Address Book", systemImage: "book.closed")
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
            Text("Add Members")
        } footer: {
            Text("Pick people from your Address Book, or add anyone by Kaspa address or domain.")
        }
    }

    /// Who is in the group so far, as a collapsed drawer of removable rows. People are added
    /// from the Address Book or by address in the section below.
    @ViewBuilder
    private var groupMemberPickerSection: some View {
        Section {
            Text("Add people to the group. You control the membership as the group admin.")
                .font(.caption)
                .foregroundColor(.secondary)

            // A collapsed drawer: the roster can run to dozens of rows, and open it would push the
            // address field below out of sight.
            DisclosureGroup(isExpanded: $membersExpanded) {
                if selectedMemberAddresses.isEmpty {
                    Text("No members added yet. Add people from your Address Book or by address below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sortedSelectedMembers, id: \.self) { address in
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
                            Button {
                                selectedMemberAddresses.remove(address)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove from group")
                        }
                    }
                }
            } label: {
                Text(selectedMemberAddresses.isEmpty ? "Members" : "Members (\(selectedMemberAddresses.count))")
                    .font(.headline)
            }
        }
    }

    /// The roster, sorted by name.
    private var sortedSelectedMembers: [String] {
        selectedMemberAddresses.sorted {
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
        // Straight to the one display-name rule (assigned name -> KNS domain -> short address).
        // This used to fall back to the short address for anyone who is not a contact, which
        // dropped the KNS domain for people offered from the follow graph.
        contactsManager.displayName(for: address)
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
        return KaspaAddress.isValidOnActiveNetwork(entry.trimmedText)
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
            let isValid = KaspaAddress.isValidOnActiveNetwork(entry.trimmedText)
            HStack {
                Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isValid ? .green : .red)
                Text(verbatim: KaspaAddress.validityText(entry.trimmedText, isValid: isValid))
                    .font(.caption)
                    .foregroundColor(isValid ? .green : .red)
            }
        }
    }

    /// Group mirror of `contactPreviewCard`: avatar + name for the address this entry resolves
    /// to, once it resolves to anything.
    @ViewBuilder
    private func groupAddressPreviewCard(for entry: GroupAddressEntry) -> some View {
        if let address = entry.effectiveAddress,
           !address.isEmpty,
           entry.resolvedAddress != nil || KaspaAddress.isValidOnActiveNetwork(address) {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[address]?.avatarURL,
                    fallbackText: memberDisplayName(address),
                    size: 40,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    // The domain the resolver already found beats waiting on the profile fetch:
                    // if you typed one, that IS the name.
                    let name = knsService.profileCache[address]?.domainName ?? entry.resolvedDomain
                    Text(name ?? memberDisplayName(address))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(address)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            // Cache-first fetch: a row whose profile is already cached costs nothing here.
            .task(id: address) { _ = await KNSService.shared.fetchProfile(for: address) }
        }
    }

    private func resolveGroupAddress(id: UUID, input: String) {
        guard let index = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        groupAddressEntries[index].resolvedAddress = nil
        groupAddressEntries[index].resolvedDomain = nil
        groupAddressEntries[index].knsError = nil
        groupAddressEntries[index].isResolvingKNS = false

        guard !trimmed.isEmpty, NameServicesClient.looksLikeName(trimmed) else { return }

        groupAddressEntries[index].isResolvingKNS = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let currentIndex = groupAddressEntries.firstIndex(where: { $0.id == id }),
                  groupAddressEntries[currentIndex].trimmedText == trimmed else {
                return
            }
            // Same priority as a 1:1 chat: the typed ending, else .kachat, .kas, .k, .kaspa.
            let results = await NameServicesClient.shared.resolveEverywhere(trimmed)
            if let resolution = NameServicesClient.primary(of: results, typed: trimmed), let address = resolution.address {
                await MainActor.run {
                    guard let i = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
                    groupAddressEntries[i].resolvedAddress = address
                    groupAddressEntries[i].resolvedDomain = resolution.display
                    groupAddressEntries[i].isResolvingKNS = false
                }
            } else {
                await MainActor.run {
                    guard let i = groupAddressEntries.firstIndex(where: { $0.id == id }) else { return }
                    groupAddressEntries[i].knsError = String(localized: "No domain found")
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


