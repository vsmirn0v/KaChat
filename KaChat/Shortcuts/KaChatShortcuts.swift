import AppIntents
import Foundation

@available(iOS 16.0, macCatalyst 16.0, *)
private struct ShortcutContactPayload: Codable {
    let alias: String
    let address: String
    let isArchived: Bool
    let isAutoAdded: Bool
    let lastMessageAtMs: Int64?
}

@available(iOS 16.0, macCatalyst 16.0, *)
private struct ShortcutMessagePayload: Codable {
    let txId: String
    let contactAlias: String
    let contactAddress: String
    let senderAddress: String
    let receiverAddress: String
    let contentPreview: String
    let contentRaw: String?
    let timestampMs: Int64
    let isOutgoing: Bool
    let messageType: String
    let deliveryStatus: String
}

@available(iOS 16.0, macCatalyst 16.0, *)
private enum KaChatShortcutHelpers {
    static func jsonString<T: Encodable>(for payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func normalizedLimit(_ input: Int, min: Int = 1, max: Int = 200) -> Int {
        Swift.max(min, Swift.min(max, input))
    }

    @MainActor
    static func resolveContact(from entity: KaChatContactEntity) throws -> Contact {
        if let existing = ContactsManager.shared.getContact(byAddress: entity.id) {
            return existing
        }
        return try ContactsManager.shared.addContact(address: entity.id, alias: entity.alias, isAutoAdded: false)
    }

    static func parseSompi(from kasText: String) throws -> UInt64 {
        let trimmed = kasText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Amount is empty")
        }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 {
            throw KasiaError.networkError("Invalid amount format")
        }
        if parts.count == 2, parts[1].count > 8 {
            throw KasiaError.networkError("Use up to 8 decimal places")
        }

        guard let amount = Decimal(string: trimmed), amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        let scaled = amount * Decimal(100_000_000)
        let rounded = NSDecimalNumber(decimal: scaled).rounding(accordingToBehavior: nil)
        return rounded.uint64Value
    }

    static func audioMimeType(for fileName: String) -> String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "webm": return "audio/webm"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/ogg"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default: return nil
        }
    }

    @MainActor
    static func previewContent(for message: ChatMessage) -> String {
        ChatService.shared.formatNotificationBody(message.content)
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct GetKaChatContactsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get KaChat Contacts"
    static var description = IntentDescription("Return KaChat contacts as JSON strings.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search")
    var searchText: String?

    @Parameter(title: "Include Archived", default: false)
    var includeArchived: Bool

    @Parameter(title: "Limit", default: 50)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let normalizedLimit = KaChatShortcutHelpers.normalizedLimit(limit)
        let query = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let source: [Contact] = includeArchived
            ? ContactsManager.shared.contacts
            : ContactsManager.shared.activeContacts

        let filtered: [Contact]
        if query.isEmpty {
            filtered = source
        } else {
            filtered = source.filter {
                $0.alias.localizedCaseInsensitiveContains(query)
                || $0.address.localizedCaseInsensitiveContains(query)
            }
        }

        let output = filtered
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
            .prefix(normalizedLimit)
            .map { contact in
                KaChatShortcutHelpers.jsonString(
                    for: ShortcutContactPayload(
                        alias: contact.alias,
                        address: contact.address,
                        isArchived: contact.isArchived,
                        isAutoAdded: contact.isAutoAdded,
                        lastMessageAtMs: contact.lastMessageAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                    )
                )
            }

        return .result(value: Array(output), dialog: "Returned \(output.count) contacts")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct GetKaChatMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get KaChat Messages"
    static var description = IntentDescription("Return recent KaChat messages as JSON strings.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Contact")
    var contact: KaChatContactEntity?

    @Parameter(title: "Include Outgoing", default: true)
    var includeOutgoing: Bool

    @Parameter(title: "Limit", default: 50)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let normalizedLimit = KaChatShortcutHelpers.normalizedLimit(limit)
        let selectedAddress = contact?.id
        var payloads: [ShortcutMessagePayload] = []

        for conversation in ChatService.shared.conversations {
            if let selectedAddress, conversation.contact.address != selectedAddress {
                continue
            }

            for message in conversation.messages {
                if !includeOutgoing && message.isOutgoing {
                    continue
                }

                let rawContent: String?
                switch message.messageType {
                case .audio:
                    rawContent = nil
                default:
                    rawContent = message.content
                }

                payloads.append(
                    ShortcutMessagePayload(
                        txId: message.txId,
                        contactAlias: conversation.contact.alias,
                        contactAddress: conversation.contact.address,
                        senderAddress: message.senderAddress,
                        receiverAddress: message.receiverAddress,
                        contentPreview: KaChatShortcutHelpers.previewContent(for: message),
                        contentRaw: rawContent,
                        timestampMs: Int64(message.timestamp.timeIntervalSince1970 * 1000),
                        isOutgoing: message.isOutgoing,
                        messageType: message.messageType.rawValue,
                        deliveryStatus: message.deliveryStatus.rawValue
                    )
                )
            }
        }

        let output = payloads
            .sorted { $0.timestampMs > $1.timestampMs }
            .prefix(normalizedLimit)
            .map { KaChatShortcutHelpers.jsonString(for: $0) }

        return .result(value: Array(output), dialog: "Returned \(output.count) messages")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SendKaChatMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send KaChat Message"
    static var description = IntentDescription("Send a text message to a KaChat contact.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Contact")
    var contact: KaChatContactEntity

    @Parameter(title: "Message")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }

        let target = try KaChatShortcutHelpers.resolveContact(from: contact)
        try await ChatService.shared.sendMessage(to: target, content: text)
        return .result(dialog: "Message sent to \(target.alias)")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SendKaChatPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Send KaChat Payment"
    static var description = IntentDescription("Send a KAS payment to a KaChat contact.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Contact")
    var contact: KaChatContactEntity

    @Parameter(title: "Amount (KAS)")
    var amountKAS: String

    @Parameter(title: "Note")
    var note: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let amountSompi = try KaChatShortcutHelpers.parseSompi(from: amountKAS)

        // Match in-app guard from ChatDetailView.
        if amountSompi < 10_000_001 {
            throw KasiaError.networkError("Minimum payment amount is 0.10000001 KAS")
        }

        let target = try KaChatShortcutHelpers.resolveContact(from: contact)
        let paymentNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        try await ChatService.shared.sendPayment(to: target, amountSompi: amountSompi, note: paymentNote)
        return .result(dialog: "Payment sent to \(target.alias)")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct SendKaChatAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "Send KaChat Audio"
    static var description = IntentDescription("Send an audio file to a KaChat contact.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Contact")
    var contact: KaChatContactEntity

    @Parameter(title: "Audio File")
    var audioFile: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try KaChatShortcutHelpers.resolveContact(from: contact)

        let data = audioFile.data
        guard !data.isEmpty else {
            throw KasiaError.networkError("Audio file is empty")
        }

        let fileName = audioFile.filename.isEmpty ? "audio.webm" : audioFile.filename
        guard let mimeType = KaChatShortcutHelpers.audioMimeType(for: fileName) else {
            throw KasiaError.networkError("Unsupported audio format")
        }

        try await ChatService.shared.sendAudio(to: target, audioData: data, fileName: fileName, mimeType: mimeType)
        return .result(dialog: "Audio sent to \(target.alias)")
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct KaChatShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetKaChatContactsIntent(),
            phrases: [
                "Get contacts in \(.applicationName)",
                "Find contacts in \(.applicationName)"
            ],
            shortTitle: "Get Contacts",
            systemImageName: "person.2"
        )

        AppShortcut(
            intent: GetKaChatMessagesIntent(),
            phrases: [
                "Get messages in \(.applicationName)",
                "Read recent messages in \(.applicationName)"
            ],
            shortTitle: "Get Messages",
            systemImageName: "message"
        )

        AppShortcut(
            intent: SendKaChatMessageIntent(),
            phrases: [
                "Send message in \(.applicationName)",
                "Send a KaChat message in \(.applicationName)"
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )

        AppShortcut(
            intent: SendKaChatPaymentIntent(),
            phrases: [
                "Send payment in \(.applicationName)",
                "Send KAS in \(.applicationName)"
            ],
            shortTitle: "Send Payment",
            systemImageName: "creditcard"
        )

        AppShortcut(
            intent: SendKaChatAudioIntent(),
            phrases: [
                "Send audio in \(.applicationName)",
                "Send voice message in \(.applicationName)"
            ],
            shortTitle: "Send Audio",
            systemImageName: "waveform"
        )
    }
}
