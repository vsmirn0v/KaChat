import Foundation
import UniformTypeIdentifiers

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MessageImageSharePayloadTest {
    static func main() throws {
        let avifBytes = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let avif = MessageImageSharePayload(
            data: avifBytes,
            fileName: "photo",
            mimeType: "image/avif"
        )
        expect(avif.fileName == "photo.avif", "AVIF payload should append the AVIF extension")
        expect(avif.contentType.identifier == "public.avif", "AVIF payload should use the AVIF content type")
        expect(avif.contentType.conforms(to: .image), "AVIF content type should conform to image")

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-image-share-payload-\(UUID().uuidString)", isDirectory: true)
        let avifURL = try avif.writeTemporaryFile(in: tempRoot)
        expect(avifURL.lastPathComponent == "photo.avif", "temporary AVIF file should keep normalized file name")
        let writtenAVIFBytes = try Data(contentsOf: avifURL)
        expect(writtenAVIFBytes == avifBytes, "temporary AVIF file should contain original bytes")

        let webp = MessageImageSharePayload(
            data: Data([0x10, 0x11]),
            fileName: "timeline.png",
            mimeType: "image/webp"
        )
        expect(webp.fileName == "timeline.webp", "WebP payload should use MIME-correct extension")
        expect(webp.contentType.identifier == "org.webmproject.webp", "WebP payload should use the WebP content type")

        let jpeg = MessageImageSharePayload(
            data: Data([0xFF, 0xD8, 0xFF]),
            fileName: "camera.jpeg",
            mimeType: "image/jpeg"
        )
        expect(jpeg.fileName == "camera.jpeg", "JPEG payload should keep an already-correct extension")
        expect(jpeg.contentType == .jpeg, "JPEG payload should use the JPEG content type")

        try? FileManager.default.removeItem(at: tempRoot)
    }
}
