import Foundation
import ImageIO
import UIKit

// Typecheck with:
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios16.0-simulator -typecheck -parse-as-library KaChat/Models/Models.swift KaChat/Utilities/ImagePrep.swift scripts/test_image_prep_avif_upload.swift
//
// Run on a booted simulator with:
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios16.0-simulator -parse-as-library KaChat/Models/Models.swift KaChat/Utilities/ImagePrep.swift scripts/test_image_prep_avif_upload.swift -o /tmp/image_prep_avif_upload_test
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl spawn booted /tmp/image_prep_avif_upload_test

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ImagePrepJPEGUploadTest {
    static func main() throws {
        let extendedFormat = UIGraphicsImageRendererFormat()
        extendedFormat.scale = 1
        extendedFormat.preferredRange = .extended
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 96, height: 64),
            format: extendedFormat
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 16, y: 12, width: 64, height: 40))
        }

        let prepared = try ImagePrep.prepareForChatMessage(image)
        expect(prepared.mimeType == "image/jpeg", "chat upload should use the cross-platform JPEG mime type")
        expect(prepared.fileName == "photo.jpg", "chat upload should use the JPEG file extension")
        expect(!prepared.data.isEmpty, "prepared image data should not be empty")
        expect(prepared.data.count <= ImagePrep.defaultChatTargetBytes, "prepared image should fit chat byte budget")
        expect(UIImage(data: prepared.data) != nil, "prepared JPEG should decode through UIImage")

        let source = CGImageSourceCreateWithData(prepared.data as CFData, nil)
        expect(source != nil, "prepared JPEG should create an ImageIO source")
        if let source {
            expect(
                CGImageSourceGetType(source) as String? == "public.jpeg",
                "prepared image data should identify as JPEG"
            )
            let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            expect(decodedImage?.bitsPerComponent == 8, "prepared HDR input should be normalized to 8-bit color")
        }

        let highQuality = try ImagePrep.prepareForChatMessage(image, targetBytes: ChatPhotoQualityPreset.high.targetBytes)
        expect(highQuality.mimeType == "image/jpeg", "custom budget should still use JPEG")
        expect(highQuality.data.count <= ChatPhotoQualityPreset.high.targetBytes, "custom budget should cap JPEG bytes")

        expect(
            ImagePrep.estimatedWirePayloadSize(targetBytes: ChatPhotoQualityPreset.high.targetBytes)
                > ImagePrep.estimatedWirePayloadSize(targetBytes: ChatPhotoQualityPreset.balanced.targetBytes),
            "higher image budget should produce a higher fee-estimate payload"
        )

        let imageSourceTypes = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        expect(imageSourceTypes.contains("public.jpeg"), "system image decoding should retain JPEG support")
        expect(imageSourceTypes.contains("org.webmproject.webp"), "system image decoding should retain WebP support")

        let legacyJPEG = try ImagePrep.prepareJPEGForChatMessage(image)
        expect(!legacyJPEG.isEmpty, "legacy JPEG preparation should remain available")
        expect(legacyJPEG.count <= ImagePrep.defaultChatTargetBytes, "legacy JPEG should fit chat byte budget")
        expect(UIImage(data: legacyJPEG) != nil, "legacy JPEG should decode through UIImage")
    }
}
