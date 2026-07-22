import SwiftUI

struct AddContactView: View {
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var groupChatService: GroupChatService
    @Environment(\.dismiss) private var dismiss

    var onAdd: ((Contact) -> Void)?
    var onCreateGroup: ((GroupChat) -> Void)?

    @State private var addressInput = ""
    @State private var alias = ""
    @State private var error: String?
    @State private var isValidAddress = false

    // KNS resolution state
    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?
    @State private var showQRScanner = false
    @State private var showSystemContactPicker = false
    @State private var pendingSystemContactLinkTarget: SystemContactLinkTarget?

    // Group chat mode
    @State private var isGroupMode = false
    @State private var groupName = ""
    @State private var groupAddressEntries: [GroupAddressEntry] = [GroupAddressEntry()]
    @State private var isCreatingGroup = false
    @State private var scanningGroupRowID: UUID?
    private static let maxGroupMembers = 10

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
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    init(onAdd: ((Contact) -> Void)? = nil, onCreateGroup: ((GroupChat) -> Void)? = nil) {
        self.onAdd = onAdd
        self.onCreateGroup = onCreateGroup
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Group Chat", isOn: $isGroupMode.animation())
                }

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

                Section("Name (Optional)") {
                    TextField("Contact name", text: $alias)
                }

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
                                createGroupChat()
                            } else {
                                addContact()
                            }
                        }
                        .disabled(isGroupMode ? !canCreateGroup : !canAdd)
                    }
                }
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
                        // Scanner dismissed without a scan (e.g. Cancel) - drop the row it was
                        // pre-appended for if the user never filled it in.
                        if let rowID = scanningGroupRowID,
                           let entry = groupAddressEntries.first(where: { $0.id == rowID }),
                           entry.trimmedText.isEmpty,
                           groupAddressEntries.count > 1 {
                            groupAddressEntries.removeAll { $0.id == rowID }
                        }
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
                            if alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                alias = candidate.displayName
                            }
                        case .nameOnly(let target):
                            pendingSystemContactLinkTarget = target
                            alias = target.displayName
                        }
                    }
                )
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

                    // Auto-fill alias with domain name if alias is empty
                    if alias.isEmpty {
                        alias = resolution.domain
                    }
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
        let aliasToUse = alias.isEmpty ? (resolvedDomain ?? "") : alias

        do {
            let existedBeforeAdd = contactsManager.getContact(byAddress: addressToUse) != nil
            let contact = try contactsManager.addContact(
                address: addressToUse,
                alias: aliasToUse
            )

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
        Section {
            TextField("Group name", text: $groupName)
        } header: {
            Text("Group Name")
        }

        Section {
            ForEach($groupAddressEntries) { $entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("kaspa:qr... or name.kas", text: $entry.text)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: entry.text) { newValue in
                                resolveGroupAddress(id: entry.id, input: newValue)
                            }

                        if groupAddressEntries.count > 1 {
                            Button {
                                groupAddressEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    groupAddressStatus(for: entry)
                }
            }

            HStack {
                Button {
                    groupAddressEntries.append(GroupAddressEntry())
                } label: {
                    Label("Add Address", systemImage: "plus.circle")
                }
                .disabled(groupAddressEntries.count >= Self.maxGroupMembers)

                Spacer()

                Button {
                    if groupAddressEntries.count >= Self.maxGroupMembers {
                        return
                    }
                    let newEntry = GroupAddressEntry()
                    groupAddressEntries.append(newEntry)
                    scanningGroupRowID = newEntry.id
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                .disabled(groupAddressEntries.count >= Self.maxGroupMembers)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Members")
        } footer: {
            Text("Up to \(Self.maxGroupMembers) addresses or KNS domains. Anyone not already a contact will be added automatically.")
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

    private var canCreateGroup: Bool {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let nonEmptyEntries = groupAddressEntries.filter { !$0.trimmedText.isEmpty }
        guard !nonEmptyEntries.isEmpty else { return false }
        return nonEmptyEntries.allSatisfy { entry in
            guard let address = entry.effectiveAddress else { return false }
            return contactsManager.isValidKaspaAddress(address)
        }
    }

    private func createGroupChat() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyEntries = groupAddressEntries.filter { !$0.trimmedText.isEmpty }

        guard !trimmedName.isEmpty else {
            error = "Enter a group name."
            return
        }
        guard !nonEmptyEntries.isEmpty else {
            error = "Add at least one address."
            return
        }
        var addresses: [String] = []
        for entry in nonEmptyEntries {
            guard let address = entry.effectiveAddress, contactsManager.isValidKaspaAddress(address) else {
                error = entry.looksLikeDomain ? "Could not resolve \(entry.trimmedText)" : "Invalid address: \(entry.trimmedText)"
                return
            }
            addresses.append(address)
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
