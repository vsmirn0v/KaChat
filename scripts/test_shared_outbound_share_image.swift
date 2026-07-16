import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SharedOutboundShareImageTest {
    static func main() throws {
        let oldJSON = """
        {
          "id": "text-share",
          "contactAddress": "kaspa:test",
          "text": "hello",
          "createdAtMs": 42,
          "autoSend": true
        }
        """.data(using: .utf8)!

        let oldShare = try JSONDecoder().decode(SharedOutboundShare.self, from: oldJSON)
        expect(oldShare.id == "text-share", "old text share id should decode")
        expect(oldShare.text == "hello", "old text share text should decode")
        expect(oldShare.image == nil, "old text share should not require image metadata")
        expect(oldShare.hasSendableContent, "old text share should still be sendable")

        let image = SharedOutboundShare.ImageAttachment(
            relativePath: "OutboundShares/share-id/photo.heic",
            fileName: "photo.heic",
            mimeType: "image/heic"
        )
        expect(
            SharedOutboundShare.ImageAttachment.normalizedFileName("../weird:name.heic") == "weird_name.heic",
            "image filenames should be reduced to a safe path component"
        )
        expect(
            SharedOutboundShare.ImageAttachment.relativePath(shareID: "abc", fileName: "../photo.png") == "OutboundShares/abc/photo.png",
            "image attachment path should stay relative to the outbound share directory"
        )
        let imageShare = SharedOutboundShare(
            id: "image-share",
            contactAddress: "kaspa:receiver",
            text: " ",
            image: image,
            createdAtMs: 99
        )

        expect(imageShare.text.isEmpty, "initializer should trim text")
        expect(imageShare.image?.relativePath == "OutboundShares/share-id/photo.heic", "image relative path should be stored")
        expect(imageShare.hasSendableContent, "image-only share should be sendable")

        let encoded = try JSONEncoder().encode(imageShare)
        let decoded = try JSONDecoder().decode(SharedOutboundShare.self, from: encoded)
        expect(decoded.image?.fileName == "photo.heic", "image filename should round-trip")
        expect(decoded.image?.mimeType == "image/heic", "image mime type should round-trip")
    }
}
