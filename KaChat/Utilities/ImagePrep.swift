import ImageIO
import UIKit

struct PreparedChatImage {
    let data: Data
    let fileName: String
    let mimeType: String
}

/// Prepares a picked photo for sending as a chat message, matching Android's
/// `ImagePrep.prepareForChatMessage` byte budget/dimension approach so a photo sent from either
/// platform lands at a similar on-chain payload size.
enum ImagePrep {
    enum PrepError: Error {
        case invalidImage
        case compressionFailed
    }

    /// Longest edge cap in pixels before compression.
    static let chatMaxDimension: CGFloat = 1280
    /// Target raw encoded image byte size - calibrated to land the final on-chain payload in the same
    /// ballpark as a voice message's ~28.7KB final wire size.
    static let defaultChatTargetBytes = 15_000
    private static let maxShrinkAttempts = 4
    private static let shrinkFactor: CGFloat = 0.7

    /// Normalizes to a standard-range bitmap, downsamples, and JPEG-compresses, binary-searching
    /// quality to fit `targetBytes` and shrinking dimensions further if quality reduction alone
    /// isn't enough.
    ///
    /// AVIF was tried here previously (matching Android's approach for smaller on-chain payloads)
    /// but was removed: while iOS's own AVIF encode/decode is reliable (guaranteed by ImageIO
    /// since iOS 16), AVIF *decode* support on Android is inconsistent across devices/OS builds -
    /// an iPhone-sent AVIF photo could permanently fail to render for an Android recipient with no
    /// way to detect or recover from that in advance. JPEG decodes everywhere, on every device on
    /// both platforms, so it's the only format guaranteed to actually reach the other person.
    static func prepareForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> PreparedChatImage {
        let data = try prepareJPEGForChatMessage(image, targetBytes: targetBytes)
        return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    static func prepareJPEGForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> Data {
        try prepareEncodedDataForChatMessage(image, targetBytes: targetBytes, encoder: jpegData)
    }

    private static func prepareEncodedDataForChatMessage(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) throws -> Data {
        var currentImage = try normalizedAndDownscaled(image, maxDimension: chatMaxDimension)

        for _ in 0..<maxShrinkAttempts {
            if let data = compressToQualityBudget(
                currentImage,
                targetBytes: targetBytes,
                encoder: encoder
            ) {
                return data
            }
            let newSize = CGSize(
                width: currentImage.size.width * shrinkFactor,
                height: currentImage.size.height * shrinkFactor
            )
            currentImage = resize(currentImage, to: newSize)
        }

        // Last resort: send whatever the lowest quality produces even if still over budget,
        // rather than rejecting the photo outright.
        guard let data = encoder(currentImage, 0.05) else {
            throw PrepError.compressionFailed
        }
        return data
    }

    /// Rough estimate of the final wire payload size for a picked-but-not-yet-compressed photo,
    /// used only for a live "fee so far" preview - the real send always measures actual bytes.
    static func estimatedWirePayloadSize(targetBytes: Int = defaultChatTargetBytes) -> Int {
        // Base64 (inner, embedding raw bytes) then the whole JSON gets base64'd again for the
        // encrypted comm payload - roughly 1.33x expansion twice.
        Int(Double(targetBytes) * 1.33 * 1.33) + 150
    }

    private static func normalizedAndDownscaled(
        _ image: UIImage,
        maxDimension: CGFloat
    ) throws -> UIImage {
        guard image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            throw PrepError.invalidImage
        }

        let longestEdge = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longestEdge)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return resize(image, to: newSize)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width >= 1, size.height >= 1 else { return image }

        // Photos can arrive as HDR/extended-sRGB images. Passing those directly to
        // `UIImage.jpegData` makes ImageIO perform an accelerated extended-range conversion;
        // on Mac Catalyst that conversion can abort inside QuartzCore while creating a Metal
        // context. Render once into an explicitly standard-range bitmap so every later JPEG
        // attempt works with ordinary 8-bit color data.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            image.draw(in: bounds)
        }
    }

    /// Binary-searches encoder quality for the highest quality that still fits `targetBytes`.
    /// Returns nil if even the lowest quality tried doesn't fit - the caller should shrink the
    /// image's dimensions and try again rather than degrade quality further.
    private static func compressToQualityBudget(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) -> Data? {
        var low: CGFloat = 0.05
        var high: CGFloat = 0.95

        guard let lowestQualityData = encoder(image, low),
              lowestQualityData.count <= targetBytes else {
            return nil
        }

        var best = lowestQualityData
        for _ in 0..<8 {
            let mid = (low + high) / 2
            guard let data = encoder(image, mid) else { break }
            if data.count <= targetBytes {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    private static func jpegData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
