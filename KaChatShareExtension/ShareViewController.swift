import Foundation
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct SharedContactRecord: Codable {
    let address: String
    let alias: String
}

private struct ShareContact: Identifiable, Hashable {
    let address: String
    let alias: String

    var id: String { address }

    var displayName: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(address.suffix(8)) : trimmed
    }
}

private struct SharedOutboundShare: Codable {
    let id: String
    let contactAddress: String
    let text: String
    let createdAtMs: Int64
    let autoSend: Bool

    init(id: String, contactAddress: String, text: String, createdAtMs: Int64, autoSend: Bool = true) {
        self.id = id
        self.contactAddress = contactAddress
        self.text = text
        self.createdAtMs = createdAtMs
        self.autoSend = autoSend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contactAddress = try container.decode(String.self, forKey: .contactAddress)
        text = try container.decode(String.self, forKey: .text)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? true
    }
}

private enum ShareStore {
    static let appGroupIdentifier = "group.com.kachat.app"
    static let contactsKey = "shared_contacts"
    static let outboundSharesKey = "outbound_shares"
    static let maxQueuedShares = 50
    static let maxShareAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
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

    static func enqueueOutboundShare(contactAddress: String, text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var shares = loadOutboundShares().filter { nowMs - $0.createdAtMs <= maxShareAgeMs }
        let share = SharedOutboundShare(
            id: UUID().uuidString,
            contactAddress: contactAddress,
            text: cleaned,
            createdAtMs: nowMs,
            autoSend: true
        )

        shares.append(share)
        if shares.count > maxQueuedShares {
            shares = Array(shares.suffix(maxQueuedShares))
        }

        guard let data = try? JSONEncoder().encode(shares) else { return nil }
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
}

private enum SharePayloadExtractor {
    static func extractText(from inputItems: [Any]) async -> String {
        var textParts: [String] = []
        var firstURLString: String?

        for case let item as NSExtensionItem in inputItems {
            for provider in item.attachments ?? [] {
                if firstURLString == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURLString(from: provider) {
                    firstURLString = url
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider, typeIdentifier: UTType.plainText.identifier) {
                    textParts.append(text)
                    continue
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                   let text = await loadText(from: provider, typeIdentifier: UTType.text.identifier) {
                    textParts.append(text)
                }
            }
        }

        let mergedText = textParts
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstURLString else {
            return mergedText
        }

        if mergedText.isEmpty {
            return firstURLString
        }

        if mergedText.contains(firstURLString) {
            return mergedText
        }

        return "\(mergedText)\n\n\(firstURLString)"
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
}

@MainActor
private final class ShareViewModel: ObservableObject {
    @Published var contacts: [ShareContact] = []
    @Published var selectedContactAddress: String?
    @Published var searchText = ""
    @Published var payloadText = ""
    @Published var isLoading = true
    @Published var isSending = false
    @Published var errorMessage: String?

    private let maxPayloadLength = 2_000

    var filteredContacts: [ShareContact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts }

        let normalized = query.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(normalized) ||
            $0.address.lowercased().contains(normalized)
        }
    }

    var canSend: Bool {
        !isLoading && !isSending && selectedContactAddress != nil && !payloadText.isEmpty
    }

    func load(inputItems: [Any]) async {
        isLoading = true
        defer { isLoading = false }

        contacts = ShareStore.loadContacts()
        if selectedContactAddress == nil {
            selectedContactAddress = contacts.first?.address
        }

        let extracted = await SharePayloadExtractor.extractText(from: inputItems)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if extracted.count > maxPayloadLength {
            payloadText = String(extracted.prefix(maxPayloadLength))
        } else {
            payloadText = extracted
        }

        if payloadText.isEmpty {
            errorMessage = "No text or link found in this share."
        }
    }

    func prepareShare() -> String? {
        let cleaned = payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            errorMessage = "No text or link to send."
            return nil
        }

        guard let selectedContactAddress else {
            errorMessage = "Select a contact first."
            return nil
        }

        errorMessage = nil
        guard let shareId = ShareStore.enqueueOutboundShare(contactAddress: selectedContactAddress, text: cleaned) else {
            errorMessage = "Could not queue this share item."
            return nil
        }
        return shareId
    }
}

private struct ShareRootView: View {
    @ObservedObject var viewModel: ShareViewModel
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Shared Content") {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing share...")
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.payloadText.isEmpty {
                        Text("No text or link found in this share item.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(viewModel.payloadText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                Section("Choose Contact") {
                    if viewModel.contacts.isEmpty {
                        Text("No contacts available. Add contacts in KaChat first.")
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Search", text: $viewModel.searchText)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        ForEach(viewModel.filteredContacts) { contact in
                            Button {
                                viewModel.selectedContactAddress = contact.address
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.displayName)
                                            .foregroundStyle(.primary)
                                        Text(contact.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if viewModel.selectedContactAddress == contact.address {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
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
            .navigationTitle("Share to KaChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .disabled(viewModel.isSending)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isSending ? "Sending..." : "Send", action: onSend)
                        .disabled(!viewModel.canSend)
                }
            }
        }
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
                self?.sendShare()
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

        let inputItems = extensionContext?.inputItems ?? []
        Task {
            await viewModel.load(inputItems: inputItems)
        }
    }

    private func cancelShare() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }

    private func sendShare() {
        guard !viewModel.isSending else { return }

        viewModel.isSending = true
        guard let shareId = viewModel.prepareShare() else {
            viewModel.isSending = false
            return
        }

        var components = URLComponents()
        components.scheme = "kachat"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "id", value: shareId)]

        guard let url = components.url else {
            viewModel.errorMessage = "Could not prepare share handoff URL."
            viewModel.isSending = false
            return
        }

        openContainingApp(url) { [weak self] success in
            guard let self else { return }
            Task { @MainActor in
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    // Keep the queued share and finish gracefully.
                    // Main app will pick it up from shared storage when user opens KaChat manually.
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
            }
        }
    }

    private func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        extensionContext?.open(url) { [weak self] success in
            guard let self else {
                completion(success)
                return
            }
            if success {
                completion(true)
                return
            }
            completion(self.openViaResponderChain(url))
        }
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

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
