import Foundation
import UIKit
import UniformTypeIdentifiers

enum ChatImageAttachmentLoader {
    enum LoadError: Error {
        case noImageData
        case unsupportedFileType
        case invalidFileURL
        case imageDecodeFailed
    }

    private static let supportedExtensions: Set<String> = [
        "png",
        "jpg",
        "jpeg",
        "heic",
        "heif"
    ]

    private static let supportedImageTypeIdentifiers = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier,
        "public.heic",
        "public.heif"
    ]

    private static let legacyMacPasteboardImageTypeIdentifiers = [
        "Apple PNG pasteboard type",
        "NeXT TIFF v4.0 pasteboard type"
    ]

    private static let supportedPasteboardImageTypeIdentifiers =
        supportedImageTypeIdentifiers + legacyMacPasteboardImageTypeIdentifiers

    static let supportedDropTypeIdentifiers = [
        UTType.fileURL.identifier
    ] + supportedImageTypeIdentifiers

    static func isSupportedImageFileName(_ fileName: String) -> Bool {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }

    static func image(from data: Data) -> UIImage? {
        UIImage(data: data)
    }

    static func loadImageData(from url: URL) throws -> Data {
        guard isSupportedImageFileName(url.lastPathComponent) else {
            throw LoadError.unsupportedFileType
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard image(from: data) != nil else {
            throw LoadError.imageDecodeFailed
        }
        return data
    }

    static func imageData(from pasteboard: UIPasteboard) -> Data? {
        if let data = imageDataFromPasteboardFileURLs(pasteboard) {
            return data
        }

        for typeIdentifier in supportedPasteboardImageTypeIdentifiers {
            if let data = pasteboard.data(forPasteboardType: typeIdentifier),
               image(from: data) != nil {
                return data
            }
        }

        guard let image = pasteboard.image else { return nil }
        return image.pngData() ?? image.jpegData(compressionQuality: 0.95)
    }

    private static func imageDataFromPasteboardFileURLs(_ pasteboard: UIPasteboard) -> Data? {
        for item in pasteboard.items {
            guard let value = item[UTType.fileURL.identifier],
                  let url = fileURL(fromPasteboardValue: value),
                  let data = try? loadImageData(from: url) else {
                continue
            }
            return data
        }
        return nil
    }

    private static func fileURL(fromPasteboardValue value: Any) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let url = value as? NSURL {
            return url as URL
        }
        if let data = value as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = value as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string)
            }
        }
        return nil
    }

    static func canLoadImage(from provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return true
        }
        return supportedImageTypeIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
    }

    static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let data = try? await loadImageFileData(from: provider) {
            return data
        }

        for typeIdentifier in supportedImageTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            let data = try await loadDataRepresentation(from: provider, typeIdentifier: typeIdentifier)
            guard image(from: data) != nil else { throw LoadError.imageDecodeFailed }
            return data
        }

        throw LoadError.noImageData
    }

    private static func loadImageFileData(from provider: NSItemProvider) async throws -> Data {
        let url = try await loadFileURL(from: provider)
        return try loadImageData(from: url)
    }

    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(throwing: LoadError.invalidFileURL)
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
                    continuation.resume(throwing: LoadError.noImageData)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }
}
