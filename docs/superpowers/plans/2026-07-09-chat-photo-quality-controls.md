# Chat Photo Quality Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add global and per-photo chat image quality controls that change AVIF/JPEG target size and update pending-photo fee estimates.

**Architecture:** Store the default quality preset in `AppSettings`, keep the per-photo selected preset as `ChatDetailView` state, and pass the selected target byte budget into `ImagePrep`. A shared SwiftUI slider renders the same preset control in Settings and the pending-photo preview row.

**Tech Stack:** Swift, SwiftUI, UIKit/ImageIO, existing script-based Swift tests, Xcode iOS and Mac Catalyst builds.

---

## File Structure

- Modify `KaChat/Models/Models.swift`: add `ChatPhotoQualityPreset`, persist `AppSettings.chatPhotoQualityPreset`, and migrate old settings to `.balanced`.
- Modify `KaChat/Utilities/ImagePrep.swift`: accept a caller-supplied target byte budget and expose wire-size estimation for that budget.
- Create `KaChat/Views/Shared/ChatPhotoQualitySlider.swift`: reusable stepped slider with selected preset label and target-size guide.
- Modify `KaChat.xcodeproj/project.pbxproj`: add `ChatPhotoQualitySlider.swift` to the app target.
- Modify `KaChat/Views/Settings/SettingsView.swift`: add the global default slider in the Chats section.
- Modify `KaChat/Views/Chat/ChatDetailView.swift`: add pending-photo selected quality state, show the preview slider, update fee estimates on slider changes, and send using the selected budget.
- Create `scripts/test_chat_photo_quality_preset.swift`: focused model/settings migration tests.
- Modify `scripts/test_image_prep_avif_upload.swift`: assert custom target budget behavior and wire-size estimate mapping.

## Task 1: Persist Chat Photo Quality Preset

**Files:**
- Modify: `KaChat/Models/Models.swift`
- Create: `scripts/test_chat_photo_quality_preset.swift`

- [x] **Step 1: Write the failing preset and settings migration test**

Create `scripts/test_chat_photo_quality_preset.swift`:

```swift
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
```

- [x] **Step 2: Run the test to verify it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library KaChat/Models/Models.swift scripts/test_chat_photo_quality_preset.swift -o /tmp/chat_photo_quality_preset_test && /tmp/chat_photo_quality_preset_test
```

Expected: compile failure because `ChatPhotoQualityPreset` and `AppSettings.chatPhotoQualityPreset` do not exist.

- [x] **Step 3: Add the model and settings migration**

In `KaChat/Models/Models.swift`, before `struct AppSettings`, add:

```swift
enum ChatPhotoQualityPreset: String, Codable, CaseIterable {
    case dataSaver
    case balanced
    case high
    case best

    static let `default`: ChatPhotoQualityPreset = .balanced

    var displayName: String {
        switch self {
        case .dataSaver: return String(localized: "Data Saver")
        case .balanced: return String(localized: "Balanced")
        case .high: return String(localized: "High")
        case .best: return String(localized: "Best")
        }
    }

    var targetBytes: Int {
        switch self {
        case .dataSaver: return 10_000
        case .balanced: return 15_000
        case .high: return 31_000
        case .best: return 50_000
        }
    }

    var targetSizeText: String {
        "~\(targetBytes / 1_000) KB"
    }

    var summaryText: String {
        "\(displayName) · \(targetSizeText)"
    }

    var sliderValue: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    init(sliderValue: Double) {
        let index = Int(sliderValue.rounded())
        let clamped = min(max(index, 0), Self.allCases.count - 1)
        self = Self.allCases[clamped]
    }
}
```

Then add `var chatPhotoQualityPreset: ChatPhotoQualityPreset` to `AppSettings`, include it in `default`, `CodingKeys`, the memberwise initializer, `init(from:)`, and `encode(to:)`. Decode missing values with:

```swift
chatPhotoQualityPreset = try container.decodeIfPresent(ChatPhotoQualityPreset.self, forKey: .chatPhotoQualityPreset) ?? .default
```

- [x] **Step 4: Run the test to verify it passes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library KaChat/Models/Models.swift scripts/test_chat_photo_quality_preset.swift -o /tmp/chat_photo_quality_preset_test && /tmp/chat_photo_quality_preset_test
```

Expected: exit 0.

## Task 2: Parameterize Chat Image Encoding Budget

**Files:**
- Modify: `KaChat/Utilities/ImagePrep.swift`
- Modify: `scripts/test_image_prep_avif_upload.swift`

- [x] **Step 1: Write failing image budget assertions**

In `scripts/test_image_prep_avif_upload.swift`, after the existing `prepared` assertions, add:

```swift
let highQuality = try ImagePrep.prepareForChatMessage(image, targetBytes: ChatPhotoQualityPreset.high.targetBytes)
expect(highQuality.mimeType == "image/avif", "custom budget should still prefer AVIF")
expect(highQuality.data.count <= ChatPhotoQualityPreset.high.targetBytes, "custom budget should cap AVIF bytes")

expect(
    ImagePrep.estimatedWirePayloadSize(targetBytes: ChatPhotoQualityPreset.high.targetBytes)
        > ImagePrep.estimatedWirePayloadSize(targetBytes: ChatPhotoQualityPreset.balanced.targetBytes),
    "higher image budget should produce a higher fee-estimate payload"
)
```

Update the compile/run commands in the file comments to include `KaChat/Models/Models.swift`.

- [x] **Step 2: Typecheck to verify it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios16.0-simulator -typecheck -parse-as-library KaChat/Models/Models.swift KaChat/Utilities/ImagePrep.swift scripts/test_image_prep_avif_upload.swift
```

Expected: failure because `prepareForChatMessage(_:targetBytes:)` and `estimatedWirePayloadSize(targetBytes:)` do not exist.

- [x] **Step 3: Add target budget parameters**

In `KaChat/Utilities/ImagePrep.swift`:

```swift
static func prepareForChatMessage(
    _ image: UIImage,
    targetBytes: Int = defaultChatTargetBytes
) throws -> PreparedChatImage {
    if let data = try? prepareEncodedDataForChatMessage(image, targetBytes: targetBytes, encoder: avifData) {
        return PreparedChatImage(data: data, fileName: "photo.avif", mimeType: "image/avif")
    }

    let data = try prepareJPEGForChatMessage(image, targetBytes: targetBytes)
    return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
}

static func prepareJPEGForChatMessage(
    _ image: UIImage,
    targetBytes: Int = defaultChatTargetBytes
) throws -> Data {
    try prepareEncodedDataForChatMessage(image, targetBytes: targetBytes, encoder: jpegData)
}
```

Update `prepareEncodedDataForChatMessage` to accept `targetBytes: Int` and pass it into `compressToQualityBudget`.

Add:

```swift
static func estimatedWirePayloadSize(targetBytes: Int = defaultChatTargetBytes) -> Int {
    Int(Double(targetBytes) * 1.33 * 1.33) + 150
}
```

Remove or replace the old no-argument implementation body so the existing call still works through the default parameter.

- [x] **Step 4: Typecheck to verify it passes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios16.0-simulator -typecheck -parse-as-library KaChat/Models/Models.swift KaChat/Utilities/ImagePrep.swift scripts/test_image_prep_avif_upload.swift
```

Expected: exit 0.

## Task 3: Add Reusable Photo Quality Slider View

**Files:**
- Create: `KaChat/Views/Shared/ChatPhotoQualitySlider.swift`
- Modify: `KaChat.xcodeproj/project.pbxproj`

- [x] **Step 1: Create the shared SwiftUI control**

Create `KaChat/Views/Shared/ChatPhotoQualitySlider.swift`:

```swift
import SwiftUI

struct ChatPhotoQualitySlider: View {
    @Binding var preset: ChatPhotoQualityPreset
    var title: LocalizedStringKey = "Photo quality"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(preset.summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Slider(
                value: Binding(
                    get: { preset.sliderValue },
                    set: { preset = ChatPhotoQualityPreset(sliderValue: $0) }
                ),
                in: 0...Double(ChatPhotoQualityPreset.allCases.count - 1),
                step: 1
            )
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(preset.summaryText))
        }
    }
}
```

- [x] **Step 2: Add the file to the Xcode project**

In `KaChat.xcodeproj/project.pbxproj`, add these exact entries:

In the `PBXBuildFile` section:

```text
		CPQS00010001000100000001 /* ChatPhotoQualitySlider.swift in Sources */ = {isa = PBXBuildFile; fileRef = CPQS00010001000000000001 /* ChatPhotoQualitySlider.swift */; };
```

In the `PBXFileReference` section:

```text
		CPQS00010001000000000001 /* ChatPhotoQualitySlider.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ChatPhotoQualitySlider.swift; sourceTree = "<group>"; };
```

In the `E8F100132D4C0001000000FF /* Shared */` group children, insert after `E8F100142D4C0001000001FF /* QRScannerView.swift */`:

```text
				CPQS00010001000000000001 /* ChatPhotoQualitySlider.swift */,
```

In the main app `PBXSourcesBuildPhase` files list, insert after `E8F100152D4C0001000001FF /* QRScannerView.swift in Sources */`:

```text
				CPQS00010001000100000001 /* ChatPhotoQualitySlider.swift in Sources */,
```

- [x] **Step 3: Build to verify the new file is compiled**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIGURATION=Debug ACTION=build scripts/ci_xcodebuild.sh
```

Expected: `** BUILD SUCCEEDED **`.

## Task 4: Add the Global Settings Slider

**Files:**
- Modify: `KaChat/Views/Settings/SettingsView.swift`

- [x] **Step 1: Add the Settings row**

In the `Section("Chats")` block, after `Show contact balance`, add:

```swift
ChatPhotoQualitySlider(
    preset: Binding(
        get: { settingsViewModel.settings.chatPhotoQualityPreset },
        set: { newValue in
            settingsViewModel.settings.chatPhotoQualityPreset = newValue
            settingsViewModel.saveSettings()
        }
    )
)
```

- [x] **Step 2: Build to verify the Settings UI compiles**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIGURATION=Debug ACTION=build scripts/ci_xcodebuild.sh
```

Expected: `** BUILD SUCCEEDED **`.

## Task 5: Wire Pending Photo Preview, Fee Estimate, and Send Budget

**Files:**
- Modify: `KaChat/Views/Chat/ChatDetailView.swift`

- [x] **Step 1: Add pending-photo quality state**

Near `@State private var pendingPhotoImage: UIImage?`, add:

```swift
@State private var pendingPhotoQualityPreset: ChatPhotoQualityPreset = .default
```

- [x] **Step 2: Reset and initialize per-photo quality**

In `attachImageData(_:)`, before `pendingPhotoImage = image`, add:

```swift
pendingPhotoQualityPreset = settingsViewModel.settings.chatPhotoQualityPreset
```

In `cancelPendingPhoto()` and the successful send cleanup block, reset:

```swift
pendingPhotoQualityPreset = settingsViewModel.settings.chatPhotoQualityPreset
```

- [x] **Step 3: Update pending photo fee estimation to use the selected target**

Change `schedulePhotoFeeEstimate()` to call:

```swift
let dummyPayload = Data(
    count: ImagePrep.estimatedWirePayloadSize(targetBytes: pendingPhotoQualityPreset.targetBytes)
)
```

If the slider changes, call `schedulePhotoFeeEstimate()` only when a pending photo exists.

- [x] **Step 4: Expand the pending photo row**

Replace the current `pendingPhotoRow(_:)` internals with a compact preview and slider:

```swift
VStack(alignment: .leading, spacing: 8) {
    HStack(spacing: 10) {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))

        if isCompressingPhoto {
            ProgressView()
            Text("Sending…")
                .foregroundColor(.secondary)
        } else {
            Text("Photo")
                .foregroundColor(.primary)
        }

        Spacer()

        Button {
            cancelPendingPhoto()
        } label: {
            Image(systemName: "trash")
                .foregroundColor(.red)
        }
        .disabled(isCompressingPhoto)
    }

    ChatPhotoQualitySlider(preset: $pendingPhotoQualityPreset)
        .disabled(isCompressingPhoto)
}
.onChange(of: pendingPhotoQualityPreset) { _ in
    guard pendingPhotoImage != nil else { return }
    schedulePhotoFeeEstimate()
}
.padding(.horizontal, 12)
.padding(.vertical, 8)
.background(glassBackground(cornerRadius: 20))
```

- [x] **Step 5: Send using the selected target**

In `sendPendingPhotoAsync()`, change:

```swift
let preparedImage = try ImagePrep.prepareForChatMessage(
    image,
    targetBytes: pendingPhotoQualityPreset.targetBytes
)
```

- [x] **Step 6: Build both supported surfaces**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIGURATION=Debug ACTION=build scripts/ci_xcodebuild.sh
```

Expected: `** BUILD SUCCEEDED **`.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project KaChat.xcodeproj -scheme KaChat -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/DerivedData-Catalyst-CI -disableAutomaticPackageResolution COMPILER_INDEX_STORE_ENABLE=NO build
```

Expected: `** BUILD SUCCEEDED **`.

## Task 6: Final Verification

**Files:**
- Verify all modified files.

- [x] **Step 1: Run focused tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library KaChat/Models/Models.swift scripts/test_chat_photo_quality_preset.swift -o /tmp/chat_photo_quality_preset_test && /tmp/chat_photo_quality_preset_test
```

Expected: exit 0.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios16.0-simulator -typecheck -parse-as-library KaChat/Models/Models.swift KaChat/Utilities/ImagePrep.swift scripts/test_image_prep_avif_upload.swift
```

Expected: exit 0.

- [x] **Step 2: Run build checks**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIGURATION=Debug ACTION=build scripts/ci_xcodebuild.sh
```

Expected: `** BUILD SUCCEEDED **`.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project KaChat.xcodeproj -scheme KaChat -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/DerivedData-Catalyst-CI -disableAutomaticPackageResolution COMPILER_INDEX_STORE_ENABLE=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Run diff hygiene**

Run:

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors; status shows only intentional feature changes.
