import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showCreateWallet = false
    @State private var showImportWallet = false
    @State private var signingInAccountId: String?
    @State private var pendingRemovalAccount: SavedAccountSummary?
    @State private var isRemovingAccount = false
    @State private var signInErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                // Logo and Title
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.accent)

                    Text("KaChat")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Secure messaging on Kaspa BlockDAG")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // Action Buttons
                VStack(spacing: 16) {
                    if !walletManager.savedAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Saved Accounts")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            ForEach(walletManager.savedAccounts) { account in
                                HStack(spacing: 12) {
                                    Button {
                                        signIn(account)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "person.crop.circle.badge.checkmark")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(account.displayAlias)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.primary)
                                                Text(account.formattedPublicAddress)
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            Spacer()
                                            if signingInAccountId == account.id {
                                                ProgressView()
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(signingInAccountId != nil || isRemovingAccount)

                                    Button(role: .destructive) {
                                        pendingRemovalAccount = account
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                    .disabled(signingInAccountId != nil || isRemovingAccount)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    Button {
                        showCreateWallet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create New Account")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        showImportWallet = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Existing Account")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
            .navigationDestination(isPresented: $showCreateWallet) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showImportWallet) {
                ImportWalletView()
            }
            .confirmationDialog(
                "Remove Saved Account",
                isPresented: Binding(
                    get: { pendingRemovalAccount != nil },
                    set: { if !$0 { pendingRemovalAccount = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from Device", role: .destructive) {
                    guard let account = pendingRemovalAccount else { return }
                    removeSavedAccount(account)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let account = pendingRemovalAccount {
                    Text("This removes \(account.displayAlias) (\(account.shortPublicAddress)) and its local data from this device.")
                } else {
                    Text("This account will be removed from this device.")
                }
            }
            .task {
                // Start node pool discovery early so it's ready when wallet is created/imported
                await NodePoolService.shared.startEarlyDiscovery()
            }
            .alert(
                "Sign In Failed",
                isPresented: Binding(
                    get: { signInErrorMessage != nil },
                    set: { if !$0 { signInErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(signInErrorMessage ?? "Unable to sign in to this account.")
            }
        }
    }

    private func signIn(_ account: SavedAccountSummary) {
        guard signingInAccountId == nil, !isRemovingAccount else { return }
        signInErrorMessage = nil
        signingInAccountId = account.id
        Task {
            let didSignIn = await walletManager.signInToSavedAccount(account)
            await MainActor.run {
                if !didSignIn {
                    signInErrorMessage = walletManager.error?.localizedDescription ?? "Unable to sign in to this account."
                }
                signingInAccountId = nil
            }
        }
    }

    private func removeSavedAccount(_ account: SavedAccountSummary) {
        guard !isRemovingAccount else { return }
        isRemovingAccount = true
        Task {
            await walletManager.removeSavedAccount(account)
            await MainActor.run {
                signingInAccountId = nil
                isRemovingAccount = false
                pendingRemovalAccount = nil
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(WalletManager.shared)
}
