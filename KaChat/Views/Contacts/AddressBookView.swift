import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The Address Book (Kaspa Hub > Address Book): saved Kaspa addresses with a name and a note, per
// wallet. It replaced syncing with the phone's Contacts - see `AddressBookManager`.

/// Kaspa Hub > Address Book (also a dock tab, if placed there).
struct AddressBookView: View {
    @ObservedObject private var book = AddressBookManager.shared
    @ObservedObject private var nextcloud = NextcloudService.shared
    @State private var search = ""
    @State private var showAdd = false
    @State private var showImportExport = false
    @State private var showFileImporter = false
    @State private var showNextcloudImporter = false
    @State private var exportFile: ExportedFile?
    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success
    @State private var toastToken = UUID()

    private var shown: [AddressBookEntry] { book.search(search) }

    /// A written export waiting for the share sheet.
    private struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

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
                    // Always showing: hidden until you pull the list down, it read as pull-to-refresh.
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: Text("Search names and addresses"))
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showImportExport = true
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel(Text("Import or export"))
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
            .sheet(isPresented: $showImportExport) { importExportSheet }
            .sheet(item: $exportFile) { file in
                AddressBookShareSheet(fileURL: file.url)
            }
            .sheet(isPresented: $showNextcloudImporter) {
                NextcloudFileSelectView(allowedExtensions: ["json"]) { file in
                    importFromNextcloud(file)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    showToast(AppLocalization.string("Couldn't read that file."), style: .error)
                    return
                }
                runImport(data)
            }
            .toast(message: toastMessage, style: toastStyle)
        }
    }

    // MARK: Import / export

    private var importExportSheet: some View {
        VStack(spacing: 12) {
            Text("Import or Export")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "Import File",
                subtitle: "Add addresses from an Address Book export.",
                systemImage: "square.and.arrow.down"
            ) {
                showImportExport = false
                DispatchQueue.main.async { showFileImporter = true }
            }
            ActionSheetRow(
                title: "Export File",
                subtitle: "Save this Address Book, with its photos, to a file.",
                systemImage: "square.and.arrow.up"
            ) {
                showImportExport = false
                exportToFile()
            }
            if nextcloud.isConnected {
                ActionSheetRow(
                    title: "Import from Nextcloud",
                    subtitle: "Pick an Address Book export from your Nextcloud.",
                    systemImage: "icloud.and.arrow.down"
                ) {
                    showImportExport = false
                    DispatchQueue.main.async { showNextcloudImporter = true }
                }
                ActionSheetRow(
                    title: "Export to Nextcloud",
                    subtitle: "Save it to the KaChat folder in your Nextcloud, to import on any device.",
                    systemImage: "icloud.and.arrow.up"
                ) {
                    showImportExport = false
                    exportToNextcloud()
                }
            } else {
                Text("Connect Nextcloud in Settings > Storage to also save it there and import it on another device.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(nextcloud.isConnected ? 450 : 330)])
        .presentationDragIndicator(.visible)
    }

    /// The export as a file in a temporary folder, or nil (with a toast) when there is nothing to
    /// write or the write fails.
    private func writeExport() -> URL? {
        guard !book.entries.isEmpty else {
            showToast(AppLocalization.string("Nothing to export yet. Add an address first."), style: .error)
            return nil
        }
        do {
            let data = try book.exportData()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("address_book_exports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(AddressBookManager.exportFileName())
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            showToast(AppLocalization.string("Export failed. Couldn't write the file."), style: .error)
            return nil
        }
    }

    private func exportToFile() {
        guard let url = writeExport() else { return }
        // One turn later: the share sheet can't present while the import/export sheet leaves.
        DispatchQueue.main.async { exportFile = ExportedFile(url: url) }
    }

    private func exportToNextcloud() {
        guard let url = writeExport(), let data = try? Data(contentsOf: url) else { return }
        Task {
            do {
                let path = try await NextcloudService.shared.uploadToKaChatFolder(
                    data: data, filename: url.lastPathComponent, contentType: "application/json", keepSpaces: true
                )
                showToast(String(format: AppLocalization.string("Saved to %@ in Nextcloud."), path))
            } catch {
                showToast(String(format: AppLocalization.string("Export to Nextcloud failed: %@"), UserFacingError.message(for: error)), style: .error)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func importFromNextcloud(_ file: NextcloudFile) {
        Task {
            do {
                runImport(try await NextcloudService.shared.downloadFile(file.path, maxBytes: 50_000_000))
            } catch {
                showToast(String(format: AppLocalization.string("Import from Nextcloud failed: %@"), UserFacingError.message(for: error)), style: .error)
            }
        }
    }

    private func runImport(_ data: Data) {
        do {
            let result = try book.importExport(data)
            var message = result.added + result.updated == 0
                ? AppLocalization.string("Already up to date. Every address in the file is saved.")
                : String(format: AppLocalization.string("Imported: %lld added, %lld updated."), result.added, result.updated)
            if result.skipped > 0 {
                message += " " + String(format: AppLocalization.string("Skipped %lld from the other network."), result.skipped)
            }
            showToast(message)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
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
                        .disabled(walletManager.currentWallet == nil || otherNetwork != nil)
                        if !isOwnAddress {
                            Button {
                                openChat(with: entry.address)
                            } label: {
                                Label("Message", systemImage: "bubble.left")
                            }
                            .disabled(otherNetwork != nil)
                        }
                    } footer: {
                        if let otherNetwork { Text(verbatim: otherNetwork) }
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

    /// Why this entry can't be paid or messaged here: it's the other network's address (saved
    /// before IOS-063, or restored from a backup).
    private var otherNetwork: String? { KaspaAddress.otherNetworkReason(address) }

    /// The same path KaPosts takes to open a chat from anywhere in the app.
    private func openChat(with address: String) {
        guard KaspaAddress.isValidOnActiveNetwork(address) else { return }
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
    /// A typed domain: what it resolved to (.kachat first) and every service's answer.
    @State private var resolvedAddress: String?
    @State private var resolvedName: String?
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var isResolving = false
    @State private var lookupError: String?

    /// The address being saved: the one this editor was opened for, else what the typed domain
    /// resolved to, else what was typed.
    private var enteredAddress: String { address ?? resolvedAddress ?? addressInput }

    private var showsAssignedPhoto: Bool {
        switch pendingPhoto {
        case .some(.some): return true
        case .some(.none): return false
        case .none: return book.hasPhoto(for: enteredAddress)
        }
    }
    private var existing: AddressBookEntry? { book.entry(for: enteredAddress) }
    private var effectiveAddress: String { AddressBookManager.normalize(enteredAddress) }

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
                        TextField("kaspa:qr... or domain", text: $addressInput, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: addressInput) { resolveIfName($0) }
                        if isResolving {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8)
                                Text("Looking up domain...")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        } else if let resolvedAddress {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Resolved: \(resolvedName ?? "")", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                Text(verbatim: resolvedAddress)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else if let lookupError {
                            Label(lookupError, systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        if !isResolving {
                            OtherDomainsDropdown(resolutions: nameResolutions, selected: selectedTLD, onSelect: selectResolution)
                        }
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

    /// A typed name resolves on every service, .kachat first; the entry saves the address.
    private func resolveIfName(_ input: String) {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedAddress = nil
        resolvedName = nil
        nameResolutions = []
        selectedTLD = nil
        lookupError = nil
        isResolving = false
        guard !typed.isEmpty, NameServicesClient.looksLikeName(typed) else { return }
        isResolving = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == typed else { return }
            let results = await NameServicesClient.shared.resolveEverywhere(typed)
            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == typed else { return }
            nameResolutions = results
            isResolving = false
            if let primary = NameServicesClient.primary(of: results, typed: typed) {
                selectResolution(primary)
            } else {
                lookupError = NameServicesClient.notFoundMessage(typed: typed, results: results)
            }
        }
    }

    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedName = resolution.display
        selectedTLD = resolution.tld
        lookupError = nil
        // the name they're known by, unless one was typed already
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = resolution.display }
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

/// Pick from the Address Book, full screen: one address (New Chat, the Send screens), or several
/// at once with ticks (New Group).
struct AddressBookPickerSheet: View {
    private enum Mode {
        case single((AddressBookEntry) -> Void)
        case multiple((Set<String>), ([AddressBookEntry]) -> Void)
    }

    private let mode: Mode
    /// Never offered (your own address, in a group).
    private let excluding: String?

    /// One address: tapping a row picks it and closes.
    init(onSelect: @escaping (AddressBookEntry) -> Void) {
        mode = .single(onSelect)
        excluding = nil
    }

    /// Several: rows tick on and off (starting from `preselected`); Add hands back every ticked
    /// entry.
    init(preselected: Set<String>, excluding: String? = nil, onDone: @escaping ([AddressBookEntry]) -> Void) {
        mode = .multiple(Set(preselected.map(AddressBookManager.normalize)), onDone)
        self.excluding = excluding.map(AddressBookManager.normalize)
    }

    @ObservedObject private var book = AddressBookManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var ticked: Set<String> = []
    @State private var seeded = false

    private var isMultiple: Bool {
        if case .multiple = mode { return true }
        return false
    }

    private var shown: [AddressBookEntry] {
        book.search(search).filter { AddressBookManager.normalize($0.address) != excluding }
    }

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
                    List(shown) { entry in
                        // the other network's address can't be chatted with or added to a group
                        let otherNetwork = KaspaAddress.otherNetworkReason(entry.address)
                        Button {
                            tap(entry)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    AddressBookRow(entry: entry)
                                    if let otherNetwork {
                                        Text(verbatim: otherNetwork)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                Spacer(minLength: 8)
                                if isMultiple {
                                    Image(systemName: ticked.contains(AddressBookManager.normalize(entry.address))
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundColor(ticked.contains(AddressBookManager.normalize(entry.address))
                                                         ? .accentColor : .secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(otherNetwork != nil)
                        .opacity(otherNetwork != nil ? 0.5 : 1)
                    }
                    .listStyle(.insetGrouped)
                    // Always showing: hidden until you pull the list down, it read as pull-to-refresh.
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: Text("Search names and addresses"))
                }
            }
            .navigationTitle("Address Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if case .multiple(_, let onDone) = mode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onDone(book.entries.filter {
                                ticked.contains(AddressBookManager.normalize($0.address)) && KaspaAddress.isValidOnActiveNetwork($0.address)
                            })
                            dismiss()
                        } label: {
                            Text(ticked.isEmpty ? "Done" : "Add (\(ticked.count))")
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if case .multiple(let preselected, _) = mode {
                    let saved = Set(book.entries.map { AddressBookManager.normalize($0.address) })
                    ticked = preselected.intersection(saved)
                }
            }
        }
    }

    private func tap(_ entry: AddressBookEntry) {
        guard KaspaAddress.isValidOnActiveNetwork(entry.address) else { return }
        switch mode {
        case .single(let onSelect):
            onSelect(entry)
            dismiss()
        case .multiple:
            let key = AddressBookManager.normalize(entry.address)
            if ticked.contains(key) { ticked.remove(key) } else { ticked.insert(key) }
        }
    }
}

/// The system share sheet for an Address Book export (Files, AirDrop, Mail, ...).
private struct AddressBookShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
