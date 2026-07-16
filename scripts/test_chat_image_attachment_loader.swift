import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ChatImageAttachmentLoaderTest {
    static func main() throws {
        expect(ChatImageAttachmentLoader.isSupportedImageFileName("photo.png"), "PNG files should be accepted")
        expect(ChatImageAttachmentLoader.isSupportedImageFileName("photo.jpeg"), "JPEG files should be accepted")
        expect(ChatImageAttachmentLoader.isSupportedImageFileName("photo.JPG"), "JPG files should be accepted case-insensitively")
        expect(ChatImageAttachmentLoader.isSupportedImageFileName("photo.heic"), "HEIC files should be accepted")
        expect(ChatImageAttachmentLoader.isSupportedImageFileName("photo.heif"), "HEIF files should be accepted")
        expect(!ChatImageAttachmentLoader.isSupportedImageFileName("notes.pdf"), "non-image files should be rejected")

        expect(
            ChatImageAttachmentLoader.supportedDropTypeIdentifiers.contains("public.file-url"),
            "drop should accept Finder file URLs"
        )
        expect(
            ChatImageAttachmentLoader.supportedDropTypeIdentifiers.contains("public.png"),
            "drop should accept PNG representations"
        )
        expect(
            ChatImageAttachmentLoader.supportedDropTypeIdentifiers.contains("public.jpeg"),
            "drop should accept JPEG representations"
        )
        expect(
            ChatImageAttachmentLoader.supportedDropTypeIdentifiers.contains("public.heic"),
            "drop should accept HEIC representations"
        )
        expect(
            ChatImageAttachmentLoader.supportedDropTypeIdentifiers.contains("public.heif"),
            "drop should accept HEIF representations"
        )

        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 8))
        }
        guard let pngData = image.pngData() else {
            fputs("FAIL: test PNG generation failed\n", stderr)
            exit(1)
        }

        expect(ChatImageAttachmentLoader.image(from: pngData) != nil, "PNG bytes should decode to an image")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kachat-attachment-\(UUID().uuidString).png")
        try pngData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loadedData = try ChatImageAttachmentLoader.loadImageData(from: tempURL)
        expect(loadedData == pngData, "file loader should return original image bytes")
        expect(ChatImageAttachmentLoader.image(from: loadedData) != nil, "loaded file bytes should decode to an image")

        let pasteboardName = UIPasteboard.Name("kachat-image-attachment-\(UUID().uuidString)")
        guard let pasteboard = UIPasteboard(name: pasteboardName, create: true) else {
            fputs("FAIL: test pasteboard creation failed\n", stderr)
            exit(1)
        }
        defer { UIPasteboard.remove(withName: pasteboardName) }
        pasteboard.items = [[UTType.fileURL.identifier: tempURL.absoluteString]]

        let pastedFileData = ChatImageAttachmentLoader.imageData(from: pasteboard)
        expect(pastedFileData == pngData, "pasteboard file URLs should load supported image files")

        guard let cgImage = image.cgImage else {
            fputs("FAIL: test image CGImage generation failed\n", stderr)
            exit(1)
        }
        let tiffData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            tiffData,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            fputs("FAIL: test TIFF destination creation failed\n", stderr)
            exit(1)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            fputs("FAIL: test TIFF generation failed\n", stderr)
            exit(1)
        }
        pasteboard.items = [[UTType.tiff.identifier: tiffData as Data]]

        let pastedScreenshotData = ChatImageAttachmentLoader.imageData(from: pasteboard)
        expect(pastedScreenshotData != nil, "macOS screenshot TIFF pasteboard data should load")
        expect(
            pastedScreenshotData.flatMap(ChatImageAttachmentLoader.image(from:)) != nil,
            "macOS screenshot TIFF pasteboard data should decode to an image"
        )

        pasteboard.items = [["Apple PNG pasteboard type": pngData]]
        let pastedLegacyMacPNGData = ChatImageAttachmentLoader.imageData(from: pasteboard)
        expect(pastedLegacyMacPNGData == pngData, "legacy macOS PNG pasteboard data should load")

        pasteboard.items = [["NeXT TIFF v4.0 pasteboard type": tiffData as Data]]
        let pastedLegacyMacTIFFData = ChatImageAttachmentLoader.imageData(from: pasteboard)
        expect(pastedLegacyMacTIFFData != nil, "legacy macOS TIFF pasteboard data should load")
        expect(
            pastedLegacyMacTIFFData.flatMap(ChatImageAttachmentLoader.image(from:)) != nil,
            "legacy macOS TIFF pasteboard data should decode to an image"
        )
    }
}
