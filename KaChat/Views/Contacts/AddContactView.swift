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
                        .onChange(of: isGroupMode) { newValue in
                            if newValue, editingGroupEntryID == nil || !groupAddressEntries.contains(where: { $0.id == editingGroupEntryID }) {
                                editingGroupEntryID = groupAddressEntries.first?.id
                            }
                        }
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
                if entry.id == editingGroupEntryID {
                    // The one expanded "card": address field, then Import/Paste/Scan (same
                    // size/style as the single-contact flow), then Add Address to commit it and
                    // open the next blank slot.
                    VStack(alignment: .leading, spacing: 10) {
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
                                    removeGroupEntry(entry.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
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
                            commitGroupEntry(entry.id)
                        } label: {
                            Text("Add Address")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValidGroupEntry(entry))
                    }
                    .padding(.vertical, 4)
                } else {
                    // Committed: collapsed to a single row - tap the name/address to edit it
                    // again, or tap the red button to remove it outright.
                    HStack {
                        Text(entry.trimmedText)
                            .font(.system(.body, design: entry.looksLikeDomain ? .default : .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            removeGroupEntry(entry.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        setEditingGroupEntry(entry.id)
                    }
                }
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Up to \(Self.maxGroupMembers) addresses or KNS domains. Anyone not already a contact will be added automatically.")
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
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let nonEmptyEntries = groupAddressEntries.filter { !$0.trimmedText.isEmpty }
        guard !nonEmptyEntries.isEmpty else { return false }
        guard nonEmptyEntries.allSatisfy(isValidGroupEntry) else { return false }
        return duplicateEffectiveAddresses.isEmpty
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
        guard duplicateEffectiveAddresses.isEmpty else {
            error = "The same address or KNS domain is added more than once."
            return
        }
        var addresses: [String] = []
        for entry in nonEmptyEntries {
            guard isValidGroupEntry(entry), let address = entry.effectiveAddress else {
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
