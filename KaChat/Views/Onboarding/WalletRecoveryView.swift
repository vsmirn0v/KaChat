import SwiftUI

/// Shown instead of the app when a wallet record is on this device but its keys are not.
///
/// The seed and private key are wrapped by a Secure Enclave key that never leaves the phone
/// it was made on, by design. After an iPhone restore, or if the app's secure keys were
/// reset, the record survives and the keys do not. The app used to open anyway: the address
/// and history were there, and every send and every incoming message then failed with no
/// explanation. This says what happened and offers the two ways out.
struct WalletRecoveryView: View {
    let wallet: Wallet

    @EnvironmentObject private var walletManager: WalletManager
    @State private var showImport = false
    @State private var showRemoveConfirmation = false
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "key.slash")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(spacing: 10) {
                    Text("Recovery Phrase Needed")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("This iPhone has your account but not its keys. That happens after restoring a phone from a backup, because KaChat's keys are locked to the device they were created on. Enter your recovery phrase to unlock it here. Your messages on this device are kept.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                VStack(spacing: 4) {
                    Text(wallet.alias)
                        .font(.headline)
                    Text(shortAddress)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                Spacer()
                VStack(spacing: 10) {
                    Button {
                        showImport = true
                    } label: {
                        Text("Enter Recovery Phrase")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Text(isRemoving ? "Removing…" : "Remove This Account From the Phone")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRemoving)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationDestination(isPresented: $showImport) {
                // The same flow onboarding uses: pick the source wallet, then enter the seed.
                // A successful import sets the current wallet and the app opens by itself.
                ImportSourceWalletView()
            }
            .alert("Remove this account?", isPresented: $showRemoveConfirmation) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The account and its message history are deleted from this phone. Nothing on the blockchain changes, and you can add the account again later with its recovery phrase.")
            }
            .alert("Couldn't remove", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var shortAddress: String {
        let address = wallet.publicAddress
        guard address.count > 20 else { return address }
        return "\(address.prefix(12))…\(address.suffix(8))"
    }

    private func remove() {
        isRemoving = true
        Task {
            do {
                try await walletManager.deleteWallet()
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
            isRemoving = false
        }
    }
}
