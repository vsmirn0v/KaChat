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
struct ImagePrepAVIFUploadTest {
    static func main() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 16, y: 12, width: 64, height: 40))
        }

        let prepared = try ImagePrep.prepareForChatMessage(image)
        expect(prepared.mimeType == "image/avif", "chat upload should prefer AVIF mime type")
        expect(prepared.fileName == "photo.avif", "chat upload should use AVIF file extension")
        expect(!prepared.data.isEmpty, "prepared image data should not be empty")
        expect(prepared.data.count <= ImagePrep.defaultChatTargetBytes, "prepared image should fit chat byte budget")
        expect(UIImage(data: prepared.data) != nil, "prepared AVIF should decode through UIImage")

        let highQuality = try ImagePrep.prepareForChatMessage(image, targetBytes: ChatPhotoQualityPreset.high.targetBytes)
        expect(highQuality.mimeType == "image/avif", "custom budget should still prefer AVIF")
        expect(highQuality.data.count <= ChatPhotoQualityPreset.high.targetBytes, "custom budget should cap AVIF bytes")

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
