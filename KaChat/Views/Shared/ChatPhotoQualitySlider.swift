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
