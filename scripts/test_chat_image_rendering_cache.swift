import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ChatImageRenderingCacheTest {
    static func main() throws {
        let source = try String(
            contentsOfFile: "KaChat/Views/Chat/MessageBubbleView.swift",
            encoding: .utf8
        )

        expect(
            !source.contains("let image = media?.image(cacheKey: message.txId)"),
            "MessageBubbleView.body should not synchronously decode chat images"
        )
        expect(
            source.contains("private struct LazyImageBubble"),
            "image messages should render through a lazy cached image subview"
        )
        expect(
            source.contains("thumbnailCache"),
            "image messages should keep a separate thumbnail cache for scrolling"
        )
        expect(
            source.contains("CGImageSourceCreateThumbnailAtIndex"),
            "scrolling thumbnails should be downsampled before display"
        )
        expect(
            !source.contains("thumbnail = nil"),
            "image row recycling should not clear thumbnails and force placeholder flicker"
        )
        expect(
            source.contains("thumbnailDisplaySize")
                && source.contains(".frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)"),
            "image messages should reserve stable thumbnail dimensions before async image loading completes"
        )
    }
}
