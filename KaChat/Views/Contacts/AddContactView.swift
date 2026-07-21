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
    @State private var groupAddressInputs: [String] = [""]
    @State private var isCreatingGroup = false
    private static let maxGroupMembers = 10

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
            ForEach(groupAddressInputs.indices, id: \.self) { index in
                HStack {
                    TextField("kaspa:qr... address \(index + 1)", text: $groupAddressInputs[index])
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    if groupAddressInputs.count > 1 {
                        Button {
                            groupAddressInputs.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if groupAddressInputs.count < Self.maxGroupMembers {
                Button {
                    groupAddressInputs.append("")
                } label: {
                    Label("Add Address", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Up to \(Self.maxGroupMembers) addresses. Anyone not already a contact will be added automatically.")
        }
    }

    private var canCreateGroup: Bool {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let addresses = groupAddressInputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return false }
        return addresses.allSatisfy { contactsManager.isValidKaspaAddress($0) }
    }

    private func createGroupChat() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let addresses = groupAddressInputs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedName.isEmpty else {
            error = "Enter a group name."
            return
        }
        guard !addresses.isEmpty else {
            error = "Add at least one address."
            return
        }
        for address in addresses where !contactsManager.isValidKaspaAddress(address) {
            error = "Invalid address: \(address)"
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
