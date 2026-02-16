import SwiftUI

struct GiftClaimView: View {
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                switch giftService.claimState {
                case .checking:
                    ProgressView()
                    Text("Checking eligibility...")
                        .foregroundColor(.secondary)

                case .eligible:
                    eligibleView

                case .claiming:
                    claimingView

                case .claimed(let txId):
                    claimedView(txId: txId)

                case .alreadyClaimed:
                    alreadyClaimedView

                case .unavailable(let reason):
                    unavailableView(reason: reason)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Welcome Gift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
    }

    private var eligibleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "gift.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Welcome to KaChat!")
                .font(.title2.bold())

            Text("Claim some KAS to get started with your new account.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("This welcome gift is a community-funded initiative.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                guard let address = walletManager.currentWallet?.publicAddress else { return }
                Task { await giftService.claimGift(walletAddress: address) }
            } label: {
                Text("Claim Gift")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
    }

    private var claimingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Verifying device...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func claimedView(txId: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)

            Text("Gift sent to your wallet!")
                .font(.title3.bold())

            Text(txId)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal)

            Button("Continue") {
                dismiss()
            }
            .padding(.top, 8)
            .buttonStyle(.borderedProminent)
        }
    }

    private var alreadyClaimedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(.secondary)

            Text("Gift already claimed")
                .font(.title3.bold())

            Text("This device has already received the welcome gift.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Continue") {
                dismiss()
            }
            .padding(.top, 8)
            .buttonStyle(.borderedProminent)
        }
    }

    private func unavailableView(reason: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 56))
                .foregroundColor(.secondary)

            Text("Gift unavailable")
                .font(.title3.bold())

            Text(reason)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("If claiming fails because the donation wallet is temporarily out of funds, please try again later.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Continue") {
                dismiss()
            }
            .padding(.top, 8)
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    GiftClaimView()
        .environmentObject(GiftService.shared)
        .environmentObject(WalletManager.shared)
}
