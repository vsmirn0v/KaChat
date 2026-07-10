import SwiftUI

/// Explains and lets the user adjust `chatPhotoQualityPreset` - reached from the photo picker's
/// options (gear icon) rather than the main Settings screen, since it's specifically about how
/// photos sent in chat are compressed, not a general app setting.
struct PhotoQualitySettingsSheet: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftPreset: ChatPhotoQualityPreset

    init(currentPreset: ChatPhotoQualityPreset) {
        _draftPreset = State(initialValue: currentPreset)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photo Quality")
                        .font(.title2.weight(.bold))
                    Text("Controls how much photos are compressed before sending. Higher quality looks clearer but costs a larger fee and takes longer to send; lower quality sends faster and cheaper but looks more compressed. This only affects photos you send - not ones you receive.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                ChatPhotoQualitySlider(preset: $draftPreset)

                Spacer()
            }
            .padding()
            .navigationTitle("Photo Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        settingsViewModel.settings.chatPhotoQualityPreset = draftPreset
                        settingsViewModel.saveSettings()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
