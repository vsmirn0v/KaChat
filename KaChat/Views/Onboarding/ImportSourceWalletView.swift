import SwiftUI

/// KasWare-style "which wallet is this seed from?" chooser, shown FIRST when the user taps
/// Import Existing Account (before seed entry, which then continues exactly as before). The
/// selection maps a wallet name to its identity derivation-path family (`WalletSourceFamily`,
/// rules replicated from KasWare's RESTORE_WALLETS/ADDRESS_TYPES + hd-keyring derivation), so
/// KaChat derives the chatting identity where that wallet actually kept the user's funds and
/// KNS domains. KaChat is preselected at the top; the spending chain always stays on KaChat's
/// own m/44'/111111'/1' branch regardless of this choice (see WalletManager's decision comment).
struct ImportSourceWalletView: View {

    private struct SourceWalletOption: Identifiable {
        let name: String
        let icon: String
        let family: WalletSourceFamily
        var isDefault: Bool = false

        var id: String { name }
    }

    /// Order mirrors KasWare's restore list, with KaChat first as the default.
    private static let options: [SourceWalletOption] = [
        SourceWalletOption(name: "KaChat", icon: "bubble.left.and.bubble.right.fill", family: .kaspaStandard, isDefault: true),
        SourceWalletOption(name: "KasWare Wallet", icon: "puzzlepiece.extension.fill", family: .kaspaStandard),
        SourceWalletOption(name: "Kaspium Wallet", icon: "iphone", family: .kaspaStandard),
        SourceWalletOption(name: "KDX Wallet", icon: "desktopcomputer", family: .kaspaLegacy972),
        SourceWalletOption(name: "Core Golang Cli Wallet", icon: "terminal.fill", family: .kaspaStandard),
        SourceWalletOption(name: "OKX Wallet", icon: "square.grid.2x2.fill", family: .kaspaStandard),
        SourceWalletOption(name: "OneKey Wallet", icon: "key.fill", family: .oneKey),
        SourceWalletOption(name: "Ledger Wallet", icon: "externaldrive.fill", family: .kaspaStandard)
    ]

    @State private var selectedOptionId: String = ImportSourceWalletView.options[0].id
    @State private var continueToSeedEntry = false

    private var selectedFamily: WalletSourceFamily {
        Self.options.first(where: { $0.id == selectedOptionId })?.family ?? .kaspaStandard
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)
                Text("Where is this seed phrase from?")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Different wallets store your Kaspa on different address paths. Pick where this seed phrase comes from so KaChat finds your funds and domains.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.options) { option in
                        optionRow(option)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

            Button {
                continueToSeedEntry = true
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Continue")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $continueToSeedEntry) {
            ImportWalletView(sourceFamily: selectedFamily)
        }
    }

    private func optionRow(_ option: SourceWalletOption) -> some View {
        let isSelected = selectedOptionId == option.id
        return Button {
            selectedOptionId = option.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Image(systemName: option.icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if option.isDefault {
                            Text("Default")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(option.family.pathDescription)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(glassBackground(cornerRadius: 12, selected: isSelected))
        }
        .buttonStyle(.plain)
    }

    /// The app's standard glass row treatment (see ColdStorageView and friends), with a subtle
    /// accent ring on the selected row.
    private func glassBackground(cornerRadius: CGFloat, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.18), lineWidth: selected ? 1.2 : 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

#Preview {
    NavigationStack {
        ImportSourceWalletView()
            .environmentObject(WalletManager.shared)
    }
}
