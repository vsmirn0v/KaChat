import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func source(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@main
struct PendingPhotoQualityComposerTest {
    static func main() throws {
        let chatDetail = try source("KaChat/Views/Chat/ChatDetailView.swift")
        let settings = try source("KaChat/Views/Settings/SettingsView.swift")

        expect(
            !chatDetail.contains("pendingPhotoQualityPreset"),
            "chat composer should not keep per-photo quality state"
        )
        expect(
            !chatDetail.contains("ChatPhotoQualitySlider(preset: $"),
            "chat composer should not render the quality slider"
        )
        expect(
            chatDetail.components(separatedBy: "settingsViewModel.settings.chatPhotoQualityPreset.targetBytes").count - 1 >= 2,
            "photo send and pending fee estimate should use the Settings quality preset"
        )
        expect(
            settings.contains("ChatPhotoQualitySlider("),
            "Settings should retain the global photo quality control"
        )
    }
}
