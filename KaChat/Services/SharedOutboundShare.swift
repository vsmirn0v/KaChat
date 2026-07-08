import Foundation

/// Outbound share request created by the Share Extension and consumed by the main app.
struct SharedOutboundShare: Codable {
    struct ImageAttachment: Codable, Equatable {
        static let rootDirectoryName = "OutboundShares"

        let relativePath: String
        let fileName: String
        let mimeType: String

        init(relativePath: String, fileName: String, mimeType: String) {
            self.fileName = Self.normalizedFileName(fileName)
            self.relativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "image/jpeg"
                : mimeType
        }

        static func relativePath(shareID: String, fileName: String) -> String {
            [
                rootDirectoryName,
                normalizedPathComponent(shareID, fallback: UUID().uuidString),
                normalizedFileName(fileName)
            ].joined(separator: "/")
        }

        static func normalizedFileName(_ rawFileName: String) -> String {
            normalizedPathComponent(rawFileName, fallback: "photo")
        }

        private static func normalizedPathComponent(_ rawComponent: String, fallback: String) -> String {
            let component = URL(fileURLWithPath: rawComponent).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = component
                .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
                .joined(separator: "_")
            return sanitized.isEmpty ? fallback : sanitized
        }
    }

    let id: String
    let contactAddress: String
    let text: String
    let image: ImageAttachment?
    let createdAtMs: Int64
    let autoSend: Bool

    static let maxStoredItems = 50
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    var hasSendableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil
    }

    init(
        id: String,
        contactAddress: String,
        text: String,
        image: ImageAttachment? = nil,
        createdAtMs: Int64,
        autoSend: Bool = true
    ) {
        self.id = id
        self.contactAddress = contactAddress
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.image = image
        self.createdAtMs = createdAtMs
        self.autoSend = autoSend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contactAddress = try container.decode(String.self, forKey: .contactAddress)
        text = try container.decodeIfPresent(String.self, forKey: .text)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        image = try container.decodeIfPresent(ImageAttachment.self, forKey: .image)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? true
    }
}
