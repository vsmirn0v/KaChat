import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ChatPhotoQualityPresetTest {
    static func main() throws {
        expect(ChatPhotoQualityPreset.dataSaver.targetBytes == 10_000, "Data Saver should target 10 KB")
        expect(ChatPhotoQualityPreset.balanced.targetBytes == 15_000, "Balanced should target current 15 KB default")
        expect(ChatPhotoQualityPreset.high.targetBytes == 31_000, "High should target previous-ish 31 KB size")
        expect(ChatPhotoQualityPreset.best.targetBytes == 50_000, "Best should target 50 KB")
        expect(ChatPhotoQualityPreset.default == .balanced, "Default quality should be Balanced")
        expect(ChatPhotoQualityPreset.allCases.map(\.sliderValue) == [0, 1, 2, 3], "Slider values should be stable")
        expect(ChatPhotoQualityPreset(sliderValue: 2.49) == .high, "Slider values should round to nearest preset")
        expect(ChatPhotoQualityPreset(sliderValue: 99) == .best, "Slider values should clamp to highest preset")

        let defaultSettings = AppSettings.default
        expect(defaultSettings.chatPhotoQualityPreset == .balanced, "Default settings should use Balanced")

        let oldSettingsJSON = """
        {
          "storeMessagesInICloud": true,
          "messageRetention": "forever",
          "networkType": "mainnet",
          "autoAddContacts": true,
          "syncSystemContacts": true,
          "autoCreateSystemContacts": true,
          "notificationMode": "remotePush",
          "notificationPermissionRequested": false,
          "incomingNotificationSoundEnabled": true,
          "incomingNotificationVibrationEnabled": true,
          "messagePollInterval": 10,
          "liveUpdatesEnabled": false,
          "feeEstimationEnabled": false,
          "hideAutoCreatedPaymentChats": false,
          "showContactBalance": true,
          "indexerURL": "https://indexer.kasia.fyi",
          "pushIndexerURL": "https://indexer.kasia.wtf",
          "knsBaseURL": "https://api.knsdomains.org/mainnet/api/v1",
          "kaspaRestAPIURL": "https://api.kaspa.org",
          "grpcEndpointPool": [],
          "discoverNewPeers": true
        }
        """.data(using: .utf8)!

        let migrated = try JSONDecoder().decode(AppSettings.self, from: oldSettingsJSON)
        expect(migrated.chatPhotoQualityPreset == .balanced, "Old settings should migrate to Balanced")

        var updated = migrated
        updated.chatPhotoQualityPreset = .best
        let encoded = try JSONEncoder().encode(updated)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        expect(decoded.chatPhotoQualityPreset == .best, "Photo quality should persist")
    }
}
