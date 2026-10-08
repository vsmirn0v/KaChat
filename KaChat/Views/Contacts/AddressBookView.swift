import PhotosUI
import SwiftUI
import UIKit

// The Address Book (Kaspa Hub > Address Book): saved Kaspa addresses with a name and a note, per
// wallet. It replaced syncing with the phone's Contacts - see `AddressBookManager`.

/// Kaspa Hub > Address Book (also a dock tab, if placed there).
struct AddressBookView: View {
    @ObservedObject private var book = AddressBookManager.shared
    @State private var search = ""
    @State private var showAdd = false

    private var shown: [AddressBookEntry] { book.search(search) }

    var body: some View {
        NavigationStack {
            Group {
                if book.entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(shown) { entry in
                            NavigationLink {
                                AddressBookEntryDetail(address: entry.address)
                            } label: {
                                AddressBookRow(entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { book.remove(address: shown[i].address) }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: Text("Search names and addresses"))
                }
            }
            .navigationTitle("Address Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add Address"))
                }
            }
            .sheet(isPresented: $showAdd) {
                AddressBookEntryEditor(address: nil) { _ in }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            Text("No saved addresses")
                .font(.headline)
            Text("Save the Kaspa addresses you use with a name you'll recognize. They stay in KaChat, for this wallet only, and never go into your phone's Contacts.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label("Add Address", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An Address Book picture: the photo you assigned to the entry, else exactly the avatar the
/// address set on its own profile, else the person glyph. Never a photo carried for a chat contact.
struct AddressBookAvatar: View {
    let address: String
    var size: CGFloat = 44
    /// The editor's not-yet-saved choice: a new photo, or `.some(nil)` for "removed".
    var pending: UIImage?? = nil

    @ObservedObject private var book = AddressBookManager.shared

    var body: some View {
        let _ = book.photoVersion
        let assigned: UIImage? = pending ?? book.photo(for: address)
        KNSAvatarView(
            avatarURLString: nil,
            fallbackText: "",
            size: size,
            overrideImage: assigned,
            contactAddress: address,
            includeBackupPhoto: false
        )
    }
}

/// One saved address in a list: avatar, name, short address.
struct AddressBookRow: View {
    let entry: AddressBookEntry

    var body: some View {
        HStack(spacing: 12) {
            AddressBookAvatar(address: entry.address, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: Contact.generateDefaultAlias(from: entry.address))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A saved address: send to it, message it, copy or share it, edit or delete it.
struct AddressBookEntryDetail: View {
    let address: String

    @ObservedObject private var book = AddressBookManager.shared
    @ObservedObject private var walletManager = WalletManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showSend = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var entry: AddressBookEntry? { book.entry(for: address) }
    private var isOwnAddress: Bool {
        AddressBookManager.normalize(walletManager.currentWallet?.publicAddress ?? "") == AddressBookManager.normalize(address)
    }

    var body: some View {
        Group {
            if let entry {
                List {
                    Section {
                        VStack(spacing: 10) {
                            AddressBookAvatar(address: entry.address, size: 76)
                            Text(verbatim: entry.name)
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center)
                            if !entry.note.isEmpty {
                                Text(verbatim: entry.note)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }

                    Section("Address") {
                        Text(verbatim: entry.address)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = entry.address
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy Address"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: entry.address) {
                            Label("Share Address", systemImage: "square.and.arrow.up")
                        }
                    }

                    Section {
                        Button {
                            showSend = true
                        } label: {
                            Label("Send KAS", systemImage: "paperplane")
                        }
                        .disabled(walletManager.currentWallet == nil)
                        if !isOwnAddress {
                            Button {
                                openChat(with: entry.address)
                            } label: {
                                Label("Message", systemImage: "bubble.left")
                            }
                        }
                    }

                    Section {
                        Button {
                            showEdit = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete from Address Book", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .sheet(isPresented: $showEdit) {
                    AddressBookEntryEditor(address: entry.address) { result in
                        if result == .removed { dismiss() }
                    }
                }
                .sheet(isPresented: $showSend) {
                    if let wallet = walletManager.currentWallet {
                        WithdrawKaspaView(
                            fromAddress: wallet.publicAddress,
                            availableBalanceSompi: wallet.balanceSompi,
                            prefillAddress: entry.address
                        )
                    }
                }
                .confirmationDialog(
                    Text("Delete \(entry.name) from your Address Book?"),
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        book.remove(address: entry.address)
                        dismiss()
                    }
                }
            } else {
                // Deleted (here or by a backup restore) while open.
                Text("Not in your Address Book")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(entry?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The same path KaPosts takes to open a chat from anywhere in the app.
    private func openChat(with address: String) {
        let contact = ContactsManager.shared.getOrCreateContact(address: address)
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        ChatService.shared.pendingChatNavigation = contact.address
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": contact.address])
        }
    }
}

enum AddressBookEditResult: Equatable {
    case saved, removed
}

/// Add or edit one entry. With an `address` it edits that address's entry (or adds it, with
/// `suggestedName` filled in - User Info's "Add to Address Book"); without one the address is
/// typed, pasted or scanned.
struct AddressBookEntryEditor: View {
    let address: String?
    var suggestedName: String = ""
    let onDone: (AddressBookEditResult) -> Void

    @ObservedObject private var book = AddressBookManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var addressInput = ""
    @State private var note = ""
    @State private var error: String?
    @State private var showScanner = false
    @State private var loaded = false
    @State private var photoItem: PhotosPickerItem?
    /// nil: keep what is saved; .some(image): use this photo; .some(nil): remove the photo.
    @State private var pendingPhoto: UIImage?? = nil
    @State private var pendingPhotoData: Data?

    private var showsAssignedPhoto: Bool {
        switch pendingPhoto {
        case .some(.some): return true
        case .some(.none): return false
        case .none: return book.hasPhoto(for: address ?? addressInput)
        }
    }
    private var existing: AddressBookEntry? { book.entry(for: address ?? addressInput) }
    private var effectiveAddress: String { AddressBookManager.normalize(address ?? addressInput) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        AddressBookAvatar(address: effectiveAddress, size: 84, pending: pendingPhoto)
                        HStack(spacing: 20) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label(showsAssignedPhoto ? LocalizedStringKey("Change Photo") : LocalizedStringKey("Choose Photo"),
                                      systemImage: "photo")
                            }
                            if showsAssignedPhoto {
                                Button(role: .destructive) {
                                    pendingPhoto = .some(nil)
                                    pendingPhotoData = nil
                                    photoItem = nil
                                } label: {
                                    Label("Remove Photo", systemImage: "trash")
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } footer: {
                    Text("Without a photo of your own, this shows the avatar they set on their profile.")
                }

                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Address") {
                    if let address {
                        Text(verbatim: address)
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                    } else {
                        TextField("kaspa:qr...", text: $addressInput, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    addressInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard")
                            }
                            Spacer()
                            Button {
                                showScanner = true
                            } label: {
                                Label("Scan QR", systemImage: "qrcode.viewfinder")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("Saved in KaChat for this wallet only. Never added to your phone's Contacts.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                if address != nil, existing != nil {
                    Section {
                        Button(role: .destructive) {
                            book.remove(address: effectiveAddress)
                            onDone(.removed)
                            dismiss()
                        } label: {
                            Label("Remove from Address Book", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add to Address Book" : "Edit Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveAddress.isEmpty)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    var scanned = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let q = scanned.firstIndex(of: "?") { scanned = String(scanned[..<q]) }
                    addressInput = scanned
                    showScanner = false
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let prepared = AddressBookManager.preparedPhoto(from: image),
                          let shown = UIImage(data: prepared) else {
                        error = AppLocalization.string("Couldn't use that photo.")
                        return
                    }
                    pendingPhoto = .some(shown)
                    pendingPhotoData = prepared
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let current = existing {
                    name = current.name
                    note = current.note
                } else {
                    name = suggestedName
                }
            }
        }
    }

    private func save() {
        do {
            let photo: AddressBookManager.PhotoChange
            switch pendingPhoto {
            case .none: photo = .unchanged
            case .some(.none): photo = .removed
            case .some(.some): photo = pendingPhotoData.map { .set($0) } ?? .unchanged
            }
            try book.save(address: effectiveAddress, name: name, note: note, photo: photo)
            onDone(.saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Pick a saved address (Send screens, Add Contact, New Group).
struct AddressBookPickerSheet: View {
    let onSelect: (AddressBookEntry) -> Void

    @ObservedObject private var book = AddressBookManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if book.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No saved addresses")
                            .font(.headline)
                        Text("Add addresses in Kaspa Hub > Address Book.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(book.search(search)) { entry in
                        Button {
                            onSelect(entry)
                            dismiss()
                        } label: {
                            AddressBookRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: Text("Search names and addresses"))
                }
            }
            .navigationTitle("Address Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
