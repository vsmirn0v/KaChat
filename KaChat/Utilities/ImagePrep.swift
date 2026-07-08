import UIKit

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
    /// Target raw JPEG byte size - calibrated to land the final on-chain payload in the same
    /// ballpark as a voice message's ~28.7KB final wire size.
    static let defaultChatTargetBytes = 15_000
    private static let maxShrinkAttempts = 4
    private static let shrinkFactor: CGFloat = 0.7

    /// Downsamples, then JPEG-compresses (binary-searching quality) to fit `defaultChatTargetBytes`,
    /// shrinking dimensions further and retrying if quality reduction alone isn't enough.
    static func prepareForChatMessage(_ image: UIImage) throws -> Data {
        var currentImage = downscaledIfNeeded(image, maxDimension: chatMaxDimension)

        for _ in 0..<maxShrinkAttempts {
            if let data = compressToQualityBudget(currentImage, targetBytes: defaultChatTargetBytes) {
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
        guard let data = currentImage.jpegData(compressionQuality: 0.05) else {
            throw PrepError.compressionFailed
        }
        return data
    }

    /// Rough estimate of the final wire payload size for a picked-but-not-yet-compressed photo,
    /// used only for a live "fee so far" preview - the real send always measures actual bytes.
    static func estimatedWirePayloadSize() -> Int {
        // Base64 (inner, embedding raw bytes) then the whole JSON gets base64'd again for the
        // encrypted comm payload - roughly 1.33x expansion twice.
        Int(Double(defaultChatTargetBytes) * 1.33 * 1.33) + 150
    }

    private static func downscaledIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maxDimension, longestEdge > 0 else { return image }
        let scale = maxDimension / longestEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return resize(image, to: newSize)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width >= 1, size.height >= 1 else { return image }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Binary-searches JPEG quality for the highest quality that still fits `targetBytes`.
    /// Returns nil if even the lowest quality tried doesn't fit - the caller should shrink the
    /// image's dimensions and try again rather than degrade quality further.
    private static func compressToQualityBudget(_ image: UIImage, targetBytes: Int) -> Data? {
        var low: CGFloat = 0.05
        var high: CGFloat = 0.95

        guard let lowestQualityData = image.jpegData(compressionQuality: low),
              lowestQualityData.count <= targetBytes else {
            return nil
        }

        var best = lowestQualityData
        for _ in 0..<8 {
            let mid = (low + high) / 2
            guard let data = image.jpegData(compressionQuality: mid) else { break }
            if data.count <= targetBytes {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }
}
