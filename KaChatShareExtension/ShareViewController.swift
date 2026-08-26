import Foundation
import Combine
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct SharedContactRecord: Codable {
    let address: String
    let alias: String
}

private struct SharedRecentRecord: Codable {
    let address: String
    let alias: String
    let lastUsedMs: Int64
}

private struct ShareContact: Identifiable, Hashable {
    let address: String
    let alias: String

    var id: String { address }

    var displayName: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(address.suffix(8)) : trimmed
    }

    var shortAddress: String {
        guard address.count > 24 else { return address }
        return "\(address.prefix(16))…\(address.suffix(6))"
    }
}

private struct ShareImageAttachment {
    let data: Data
    let fileName: String
    let mimeType: String

    var previewImage: UIImage? {
        UIImage(data: data)
    }
}

private struct SharePayload {
    let text: String
    let image: ShareImageAttachment?

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil
    }
}

private enum ShareStore {
    static let appGroupIdentifier = "group.com.kachat.app"
    static let contactsKey = "shared_contacts"
    static let recentsKey = "kachat_recent_conversations"
    static let outboundSharesKey = "outbound_shares"
    static let maxQueuedShares = 50
    static let maxShareAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func loadContacts() -> [ShareContact] {
        guard let data = sharedDefaults?.data(forKey: contactsKey),
              let decoded = try? JSONDecoder().decode([SharedContactRecord].self, from: data) else {
            return []
        }

        return decoded
            .map { ShareContact(address: $0.address, alias: $0.alias) }
            .sorted {
                if $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedSame {
                    return $0.address < $1.address
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    /// Recent conversations maintained by the main app (chat opens + message sends), newest first.
    /// Aliases are reconciled against the synced contact list, which is fresher.
    static func loadRecents() -> [ShareContact] {
        guard let data = sharedDefaults?.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([SharedRecentRecord].self, from: data) else {
            return []
        }

        let contactAliases = Dictionary(
            loadContacts().map { ($0.address, $0.alias) },
            uniquingKeysWith: { first, _ in first }
        )

        return decoded
            .sorted { $0.lastUsedMs > $1.lastUsedMs }
            .map { record in
                let syncedAlias = contactAliases[record.address]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let alias = (syncedAlias?.isEmpty == false) ? syncedAlias! : record.alias
                return ShareContact(address: record.address, alias: alias)
            }
    }

    static func enqueueOutboundShare(
        contactAddress: String,
        text: String,
        image: ShareImageAttachment?,
        autoSend: Bool
    ) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || image != nil else { return nil }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let existingShares = loadOutboundShares()
        existingShares
            .filter { nowMs - $0.createdAtMs > maxShareAgeMs }
            .forEach(removeStoredImageFiles)
        var shares = existingShares.filter { nowMs - $0.createdAtMs <= maxShareAgeMs }
        let shareId = UUID().uuidString
        let storedImage = storeImage(image, shareId: shareId)
        if image != nil, storedImage == nil {
            return nil
        }
        // autoSend: true  - the user confirmed the message in this extension's compose popup;
        //                   the main app sends it IMMEDIATELY on its next activation with no
        //                   further interaction. (In-extension on-chain sending is impossible:
        //                   the Kaspa REST API's POST /transactions schema has no payload field,
        //                   so a Kasia message transaction cannot be submitted outside the main
        //                   app's gRPC node pool.)
        // autoSend: false - the main app lands the user in the chat with the shared content
        //                   pre-filled in the composer instead of sending immediately.
        let share = SharedOutboundShare(
            id: shareId,
            contactAddress: contactAddress,
            text: cleaned,
            image: storedImage,
            createdAtMs: nowMs,
            autoSend: autoSend
        )

        shares.append(share)
        if shares.count > maxQueuedShares {
            shares = Array(shares.suffix(maxQueuedShares))
        }

        guard let data = try? JSONEncoder().encode(shares) else {
            removeStoredImageFiles(for: share)
            return nil
        }
        sharedDefaults?.set(data, forKey: outboundSharesKey)
        return share.id
    }

    private static func loadOutboundShares() -> [SharedOutboundShare] {
        guard let data = sharedDefaults?.data(forKey: outboundSharesKey),
              let decoded = try? JSONDecoder().decode([SharedOutboundShare].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func storeImage(
        _ image: ShareImageAttachment?,
        shareId: String
    ) -> SharedOutboundShare.ImageAttachment? {
        guard let image else { return nil }
        guard let sharedContainerURL else { return nil }

        let fileName = SharedOutboundShare.ImageAttachment.normalizedFileName(image.fileName)
        let relativePath = SharedOutboundShare.ImageAttachment.relativePath(shareID: shareId, fileName: fileName)
        let fileURL = sharedContainerURL.appendingPathComponent(relativePath, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try image.data.write(to: fileURL, options: .atomic)
            return SharedOutboundShare.ImageAttachment(
                relativePath: relativePath,
                fileName: fileName,
                mimeType: image.mimeType
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            return nil
        }
    }

    private static func removeStoredImageFiles(for share: SharedOutboundShare) {
        guard share.image != nil,
              let sharedContainerURL else { return }
        let directory = sharedContainerURL
            .appendingPathComponent(SharedOutboundShare.ImageAttachment.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(share.id, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum SharePayloadExtractor {
    private static let supportedImageTypeIdentifiers = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        "public.heic",
        "public.heif",
        UTType.image.identifier
    ]

    static func extractPayload(from inputItems: [Any]) async -> SharePayload {
        var textParts: [String] = []
        var firstURLString: String?
        var firstImage: ShareImageAttachment?

        for case let item as NSExtensionItem in inputItems {
            for provider in item.attachments ?? [] {
                let providerImage = firstImage == nil ? await loadImage(from: provider) : nil
                if firstImage == nil {
                    firstImage = providerImage
                }

                if providerImage == nil,
                   firstURLString == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURLString(from: provider) {
                    firstURLString = url
                }

                if providerImage == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider, typeIdentifier: UTType.plainText.identifier) {
                    textParts.append(text)
                    continue
                }

                if providerImage == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                   let text = await loadText(from: provider, typeIdentifier: UTType.text.identifier) {
                    textParts.append(text)
                }
            }
        }

        let mergedText = textParts
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let text: String
        if let firstURLString {
            if mergedText.isEmpty {
                text = firstURLString
            } else if mergedText.contains(firstURLString) {
                text = mergedText
            } else {
                text = "\(mergedText)\n\n\(firstURLString)"
            }
        } else {
            text = mergedText
        }

        return SharePayload(text: text, image: firstImage)
    }

    private static func loadImage(from provider: NSItemProvider) async -> ShareImageAttachment? {
        for typeIdentifier in supportedImageTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let attachment = await loadImageDataRepresentation(from: provider, typeIdentifier: typeIdentifier) {
                return attachment
            }
            if let attachment = await loadImageItem(from: provider, typeIdentifier: typeIdentifier) {
                return attachment
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadImageItem(from: provider, typeIdentifier: UTType.fileURL.identifier)
        }

        return nil
    }

    private static func loadImageDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> ShareImageAttachment? {
        guard let data = try? await loadDataRepresentation(from: provider, typeIdentifier: typeIdentifier),
              UIImage(data: data) != nil else {
            return nil
        }

        let mimeType = imageMimeType(for: data, typeIdentifier: typeIdentifier)
        return ShareImageAttachment(
            data: data,
            fileName: imageFileName(from: provider, typeIdentifier: typeIdentifier, mimeType: mimeType),
            mimeType: mimeType
        )
    }

    private static func loadImageItem(from provider: NSItemProvider, typeIdentifier: String) async -> ShareImageAttachment? {
        guard let item = try? await loadItem(from: provider, typeIdentifier: typeIdentifier) else {
            return nil
        }

        if let data = item as? Data, UIImage(data: data) != nil {
            let mimeType = imageMimeType(for: data, typeIdentifier: typeIdentifier)
            return ShareImageAttachment(
                data: data,
                fileName: imageFileName(from: provider, typeIdentifier: typeIdentifier, mimeType: mimeType),
                mimeType: mimeType
            )
        }

        if let url = item as? URL {
            return loadImageFile(from: url, provider: provider, typeIdentifier: typeIdentifier)
        }

        if let url = item as? NSURL {
            return loadImageFile(from: url as URL, provider: provider, typeIdentifier: typeIdentifier)
        }

        if let image = item as? UIImage,
           let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95) {
            return ShareImageAttachment(
                data: data,
                fileName: imageFileName(from: provider, typeIdentifier: UTType.png.identifier, mimeType: "image/png"),
                mimeType: "image/png"
            )
        }

        return nil
    }

    private static func loadImageFile(
        from url: URL,
        provider: NSItemProvider,
        typeIdentifier: String
    ) -> ShareImageAttachment? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url),
              UIImage(data: data) != nil else {
            return nil
        }

        let mimeType = imageMimeType(for: data, typeIdentifier: typeIdentifier)
        let fileName = url.lastPathComponent.isEmpty
            ? imageFileName(from: provider, typeIdentifier: typeIdentifier, mimeType: mimeType)
            : url.lastPathComponent
        return ShareImageAttachment(data: data, fileName: fileName, mimeType: mimeType)
    }

    private static func imageFileName(
        from provider: NSItemProvider,
        typeIdentifier: String,
        mimeType: String
    ) -> String {
        let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = suggestedName.isEmpty ? "photo" : suggestedName
        let currentExtension = (baseName as NSString).pathExtension
        guard currentExtension.isEmpty else {
            return SharedOutboundShare.ImageAttachment.normalizedFileName(baseName)
        }
        let preferredExtension = preferredExtension(mimeType: mimeType, typeIdentifier: typeIdentifier)
        return SharedOutboundShare.ImageAttachment.normalizedFileName("\(baseName).\(preferredExtension)")
    }

    private static func preferredExtension(mimeType: String, typeIdentifier: String) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        default:
            return UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
        }
    }

    private static func imageMimeType(for data: Data, typeIdentifier: String) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return "image/jpeg"
        }
        if typeIdentifier == "public.heic" {
            return "image/heic"
        }
        if typeIdentifier == "public.heif" {
            return "image/heif"
        }
        return UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg"
    }

    private static func loadText(from provider: NSItemProvider, typeIdentifier: String) async -> String? {
        guard let item = try? await loadItem(from: provider, typeIdentifier: typeIdentifier) else {
            return nil
        }

        if let text = item as? String {
            return text
        }

        if let attributed = item as? NSAttributedString {
            return attributed.string
        }

        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let url = item as? URL {
            return url.absoluteString
        }

        if let url = item as? NSURL {
            return url.absoluteString
        }

        return nil
    }

    private static func loadURLString(from provider: NSItemProvider) async -> String? {
        guard let item = try? await loadItem(from: provider, typeIdentifier: UTType.url.identifier) else {
            return nil
        }

        if let url = item as? URL {
            return url.absoluteString
        }

        if let url = item as? NSURL {
            return url.absoluteString
        }

        if let text = item as? String {
            return text
        }

        return nil
    }

    private static func loadItem(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: item)
            }
        }
    }

    private static func loadDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: CocoaError(.fileReadNoSuchFile))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

@MainActor
private final class ShareViewModel: ObservableObject {
    /// The flow's three screens: pick a contact, compose the message in a quick-reply style
    /// popup, then a terminal "queued" confirmation. The popup IS the completion - there is no
    /// silent dead-end anymore (the old flow completed while an app-open hack usually failed,
    /// leaving the user with nothing).
    enum Stage {
        case picking
        case composing
        case queued
    }

    @Published var contacts: [ShareContact] = []
    @Published var recentContacts: [ShareContact] = []
    @Published var selectedContactAddress: String?
    @Published var searchText = ""
    @Published var payloadText = ""
    @Published var imageAttachment: ShareImageAttachment?
    @Published var isLoading = true
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var stage: Stage = .picking
    @Published var composeText = ""
    /// Copy shown on the terminal confirmation screen (differs for send vs. edit-in-app).
    @Published var queuedConfirmationText = ""

    private let maxPayloadLength = 2_000

    var selectedContact: ShareContact? {
        guard let selectedContactAddress else { return nil }
        return recentContacts.first { $0.address == selectedContactAddress }
            ?? contacts.first { $0.address == selectedContactAddress }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredContacts: [ShareContact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            // Recents get their own section; don't repeat them in the full list.
            let recentAddresses = Set(recentContacts.map(\.address))
            return contacts.filter { !recentAddresses.contains($0.address) }
        }

        let normalized = query.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(normalized) ||
            $0.address.lowercased().contains(normalized)
        }
    }

    var canSend: Bool {
        !isLoading
            && !isSending
            && selectedContactAddress != nil
            && (!composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageAttachment != nil)
    }

    func load(inputItems: [Any], preselectedAddress: String?) async {
        isLoading = true
        defer { isLoading = false }

        contacts = ShareStore.loadContacts()
        recentContacts = ShareStore.loadRecents()

        let extracted = await SharePayloadExtractor.extractPayload(from: inputItems)
        let extractedText = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        imageAttachment = extracted.image

        if extractedText.count > maxPayloadLength {
            payloadText = String(extractedText.prefix(maxPayloadLength))
        } else {
            payloadText = extractedText
        }

        if !extracted.hasContent {
            errorMessage = "No text, link, or image found in this share."
        }

        // The user tapped a KaChat conversation direct target in the share sheet
        // (donated INSendMessageIntent) - skip the picker and land straight in compose
        // for that contact, like Apple Watch quick reply.
        if let preselectedAddress,
           contacts.contains(where: { $0.address == preselectedAddress })
            || recentContacts.contains(where: { $0.address == preselectedAddress }) {
            selectContact(address: preselectedAddress)
        }
    }

    /// Advances to the compose popup for the tapped contact. The shared text is copied into the
    /// editable compose field once; edits survive going back and picking a different contact.
    func selectContact(address: String) {
        selectedContactAddress = address
        if composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composeText = payloadText
        }
        errorMessage = nil
        stage = .composing
    }

    func backToPicker() {
        guard !isSending, stage == .composing else { return }
        errorMessage = nil
        stage = .picking
    }

    /// Queues the composed message in the App Group. `autoSend: true` means the main app sends
    /// it the moment it next activates, with no further user interaction.
    func queueComposedShare(autoSend: Bool) -> String? {
        var cleaned = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxPayloadLength {
            cleaned = String(cleaned.prefix(maxPayloadLength))
        }
        guard !cleaned.isEmpty || imageAttachment != nil else {
            errorMessage = "Nothing to send - type a message first."
            return nil
        }

        guard let selectedContactAddress else {
            errorMessage = "Select a contact first."
            return nil
        }

        errorMessage = nil
        guard let shareId = ShareStore.enqueueOutboundShare(
            contactAddress: selectedContactAddress,
            text: cleaned,
            image: imageAttachment,
            autoSend: autoSend
        ) else {
            errorMessage = "Could not queue this share. Please try again."
            return nil
        }
        return shareId
    }
}

private struct ShareRootView: View {
    @ObservedObject var viewModel: ShareViewModel
    let onCancel: () -> Void
    let onSend: () -> Void
    let onQueueForApp: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.stage {
                case .picking:
                    pickerList
                case .composing:
                    composeView
                case .queued:
                    queuedView
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    switch viewModel.stage {
                    case .picking:
                        Button("Cancel", action: onCancel)
                    case .composing:
                        Button {
                            viewModel.backToPicker()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(viewModel.isSending)
                    case .queued:
                        EmptyView()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.stage == .composing {
                        Button("Cancel", action: onCancel)
                            .disabled(viewModel.isSending)
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch viewModel.stage {
        case .picking: return "Share to KaChat"
        case .composing: return viewModel.selectedContact?.displayName ?? "New Message"
        case .queued: return ""
        }
    }

    // MARK: - Stage 1: Contact picker

    private var pickerList: some View {
        List {
            if viewModel.isLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing share...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !viewModel.recentContacts.isEmpty && !viewModel.isSearching {
                Section("Recent") {
                    ForEach(viewModel.recentContacts) { contact in
                        contactRow(contact)
                    }
                }
            }

            Section("Choose Contact") {
                if viewModel.contacts.isEmpty && viewModel.recentContacts.isEmpty {
                    Text("No contacts available. Add contacts in KaChat first.")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Search", text: $viewModel.searchText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    ForEach(viewModel.filteredContacts) { contact in
                        contactRow(contact)
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ contact: ShareContact) -> some View {
        Button {
            viewModel.selectContact(address: contact.address)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .foregroundStyle(.primary)
                    Text(contact.shortAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            // .plain buttons only hit-test the label's opaque content - without an explicit
            // content shape, taps on the row's blank space (most of it, thanks to the Spacer)
            // are dead and contacts can't be selected.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stage 2: Quick-reply compose popup

    private var composeView: some View {
        List {
            if let contact = viewModel.selectedContact {
                Section("To") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                            .foregroundStyle(.primary)
                        Text(contact.shortAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("Message") {
                if let image = viewModel.imageAttachment,
                   let previewImage = image.previewImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(image.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TextField("Message", text: $viewModel.composeText, axis: .vertical)
                    .lineLimit(3...8)
                    .disabled(viewModel.isSending)
            }

            Section {
                Button(action: onSend) {
                    HStack {
                        Spacer()
                        if viewModel.isSending {
                            ProgressView()
                                .padding(.trailing, 6)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .padding(.trailing, 2)
                        }
                        Text(viewModel.isSending ? "Queuing..." : "Send")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSend)

                Button(action: onQueueForApp) {
                    HStack {
                        Spacer()
                        Text("Edit in KaChat instead")
                            .font(.subheadline)
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSend)
            } footer: {
                Text("Send queues the message; KaChat delivers it on-chain the moment it next opens.")
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Stage 3: Queued confirmation (terminal - the sheet auto-dismisses)

    private var queuedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text(viewModel.queuedConfirmationText)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class ShareViewController: UIViewController {
    private let viewModel = ShareViewModel()
    private var didLoadData = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let rootView = ShareRootView(
            viewModel: viewModel,
            onCancel: { [weak self] in
                self?.cancelShare()
            },
            onSend: { [weak self] in
                self?.queueShare(autoSend: true)
            },
            onQueueForApp: { [weak self] in
                self?.queueShare(autoSend: false)
            }
        )

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didLoadData else { return }
        didLoadData = true

        // When the user tapped a KaChat conversation direct target in the share sheet
        // (donated INSendMessageIntent), pre-select that contact.
        let intentAddress = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier

        let inputItems = extensionContext?.inputItems ?? []
        Task {
            await viewModel.load(inputItems: inputItems, preselectedAddress: intentAddress)
        }
    }

    private func cancelShare() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }

    /// Queues the composed message in the App Group and shows the terminal confirmation.
    /// `autoSend: true` (the Send button) has the main app deliver the message on-chain the
    /// moment it next activates - no user interaction needed. `autoSend: false` ("Edit in
    /// KaChat instead") preserves the old prefill behavior: the app opens the chat with the
    /// message staged in the composer.
    ///
    /// Unlike the previous flow, the confirmation screen IS the completion: the share succeeds
    /// whether or not the best-effort app-open below manages to launch KaChat (it usually
    /// doesn't - see openViaResponderChain), because the main app also drains the queue on its
    /// next normal activation.
    private func queueShare(autoSend: Bool) {
        guard !viewModel.isSending else { return }

        viewModel.isSending = true
        guard let shareId = viewModel.queueComposedShare(autoSend: autoSend) else {
            viewModel.isSending = false
            return
        }

        viewModel.queuedConfirmationText = autoSend
            ? "Queued - sends the moment KaChat opens."
            : "Queued - KaChat opens this chat with your message ready to edit."
        viewModel.stage = .queued

        var components = URLComponents()
        components.scheme = "kachat"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "id", value: shareId)]

        if let url = components.url {
            // Best-effort app open. NSExtensionContext.open is documented to work only from
            // Today widgets; in share extensions it usually fails and on several iOS versions
            // never even calls its completion handler, so this is fire-and-forget - the queued
            // share is the source of truth either way.
            let attemptOpen: () -> Void = { [weak self] in
                guard let self else { return }
                if !self.openViaResponderChain(url) {
                    self.extensionContext?.open(url, completionHandler: nil)
                }
            }
            attemptOpen()
            // One retry: the first perform can land while the host app is mid-transition (share
            // sheet still animating) and get silently dropped by the system.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: attemptOpen)
        }

        // Complete on a delay: long enough for the user to read the confirmation and for the
        // system to process the openURL: perform (completing too close to it tears the
        // extension down before the open lands - 0.6s proved too tight on device).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        // Start from the window when attached: some hosts' view-controller responder chains
        // stop before reaching UIApplication, while window.next reaches it directly.
        var responder: UIResponder? = view.window ?? self

        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }

        return false
    }
}
