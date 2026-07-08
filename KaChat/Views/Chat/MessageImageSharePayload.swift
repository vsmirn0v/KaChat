import Foundation
import UniformTypeIdentifiers

struct MessageImageSharePayload {
    let data: Data
    let fileName: String
    let contentType: UTType

    init(data: Data, fileName: String, mimeType: String) {
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedContentType = Self.contentType(for: normalizedMimeType, fileName: fileName)
        self.data = data
        self.contentType = resolvedContentType
        self.fileName = Self.normalizedFileName(
            fileName,
            mimeType: normalizedMimeType,
            contentType: resolvedContentType
        )
    }

    func writeTemporaryFile(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let shareDirectory = directory.appendingPathComponent("kachat-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let fileURL = shareDirectory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func contentType(for mimeType: String, fileName: String) -> UTType {
        switch mimeType {
        case "image/avif":
            return UTType(filenameExtension: "avif", conformingTo: .image)
                ?? UTType(importedAs: "public.avif", conformingTo: .image)
        case "image/webp":
            return UTType(filenameExtension: "webp", conformingTo: .image)
                ?? UTType(importedAs: "org.webmproject.webp", conformingTo: .image)
        case "image/jpeg", "image/jpg":
            return .jpeg
        case "image/png":
            return .png
        case "image/gif":
            return .gif
        case "image/heic":
            return .heic
        case "image/heif":
            return UTType(filenameExtension: "heif", conformingTo: .image) ?? .image
        default:
            let fileExtension = (sanitizedPathComponent(fileName) as NSString).pathExtension
            if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .image) {
                return type
            }
            return .image
        }
    }

    private static func normalizedFileName(
        _ rawFileName: String,
        mimeType: String,
        contentType: UTType
    ) -> String {
        let pathComponent = sanitizedPathComponent(rawFileName)
        let nsName = pathComponent as NSString
        let existingExtension = nsName.pathExtension.lowercased()
        let baseName = {
            let candidate = nsName.deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? "photo" : candidate
        }()

        guard let preferredExtension = preferredFileExtension(
            for: mimeType,
            contentType: contentType
        ) else {
            return existingExtension.isEmpty ? baseName : pathComponent
        }

        if extensionMatches(existingExtension, mimeType: mimeType) {
            return "\(baseName).\(existingExtension)"
        }
        return "\(baseName).\(preferredExtension)"
    }

    private static func preferredFileExtension(for mimeType: String, contentType: UTType) -> String? {
        switch mimeType {
        case "image/avif":
            return "avif"
        case "image/webp":
            return "webp"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic":
            return "heic"
        case "image/heif":
            return "heif"
        default:
            return contentType.preferredFilenameExtension
        }
    }

    private static func extensionMatches(_ fileExtension: String, mimeType: String) -> Bool {
        guard !fileExtension.isEmpty else { return false }
        switch mimeType {
        case "image/jpeg", "image/jpg":
            return ["jpg", "jpeg", "jpe"].contains(fileExtension)
        case "image/avif":
            return fileExtension == "avif"
        case "image/webp":
            return fileExtension == "webp"
        case "image/png":
            return fileExtension == "png"
        case "image/gif":
            return fileExtension == "gif"
        case "image/heic":
            return fileExtension == "heic"
        case "image/heif":
            return fileExtension == "heif"
        default:
            return true
        }
    }

    private static func sanitizedPathComponent(_ rawFileName: String) -> String {
        let component = URL(fileURLWithPath: rawFileName).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = component
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "_")
        return sanitized.isEmpty ? "photo" : sanitized
    }
}
