import SwiftUI

/// The .kachat profile setup guide: claim your name, then avatar, banner and details, step by
/// step. Opened from Edit KaChat Profile and Profile > Help - the guide .kas used to have,
/// rebuilt for KaChat's own names (a .kas profile is edited field by field in Your Domains).
///
/// UI only until .kachat names launch: every step can be walked through, but nothing can be
/// claimed, picked or typed, and each says so. No invented names or images anywhere.
struct KachatSetupGuideView: View {
    let onClose: () -> Void

    private enum Step: Int, CaseIterable {
        case claim, avatar, banner, details, finished
    }

    @State private var step: Step = .claim

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        progressDots
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                KNSWizardBottomBar(
                    nextTitle: step == .finished ? "Done" : "Next",
                    onBack: previous.map { target in { withAnimation { step = target } } },
                    onNext: {
                        if let next = Step(rawValue: step.rawValue + 1) {
                            withAnimation { step = next }
                        } else {
                            onClose()
                        }
                    }
                )
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    private var previous: Step? {
        Step(rawValue: step.rawValue - 1)
    }

    /// One dot per step before the last, filled up to the current one.
    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.filter { $0 != .finished }, id: \.self) { dot in
                Capsule()
                    .fill(dot.rawValue <= step.rawValue ? Color.accentColor : Color(.systemGray4))
                    .frame(width: dot == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .claim:
            stepHeader(
                title: "Claim your .kachat name",
                subtitle: "It's the name people see you as across KaChat - in chats, on posts and on your profile link. Without one, people see your address."
            ) {
                KachatTabIcon.view(side: 56)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("yourname")
                        .foregroundColor(Color(.placeholderText))
                    Spacer()
                    Text(".kachat")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(fieldBackground)
                if KachatNamesService.isLaunched {
                    Text("On Testnet, claim one in Kaspa Hub > .kachat.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Registration isn't open yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if !KachatNamesService.isLaunched {
                comingSoonNote
            }

        case .avatar:
            stepHeader(
                title: "Add a profile photo",
                subtitle: "Your avatar shows next to your name everywhere in KaChat."
            ) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 120, height: 120)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color(.systemGray3))
                )
            disabledAction("Choose Photo", systemImage: "photo")
            comingSoonNote

        case .banner:
            stepHeader(
                title: "Add a banner",
                subtitle: "A wide image across the top of your profile."
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: 120)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundColor(Color(.systemGray3))
                )
            disabledAction("Choose Banner", systemImage: "photo.on.rectangle")
            comingSoonNote

        case .details:
            stepHeader(
                title: "Tell people about you",
                subtitle: "A short bio and your links. All of it is optional."
            ) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            VStack(spacing: 0) {
                ForEach(Array(Self.detailFields.enumerated()), id: \.offset) { index, field in
                    HStack {
                        Text(LocalizedStringKey(field))
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if index < Self.detailFields.count - 1 { Divider().padding(.leading, 14) }
                }
            }
            .background(fieldBackground)
            comingSoonNote

        case .finished:
            stepHeader(
                title: "That's the whole setup",
                subtitle: ".kachat names are coming soon. When they launch, this guide claims your name and saves your profile in one go."
            ) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundColor(.accentColor)
            }
        }
    }

    private static let detailFields = ["Bio", "X handle", "Website", "Telegram", "Discord user id", "Email", "GitHub"]

    private func stepHeader<Icon: View>(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 10) {
            icon()
                .frame(height: 64)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private func disabledAction(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Button {} label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .disabled(true)
    }

    private var comingSoonNote: some View {
        Text("Coming soon")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}
