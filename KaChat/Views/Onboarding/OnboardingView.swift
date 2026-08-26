import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showCreateWallet = false
    @State private var showImportWallet = false
    @State private var signingInAccountId: String?
    @State private var pendingRemovalAccount: SavedAccountSummary?
    @State private var isRemovingAccount = false
    @State private var signInErrorMessage: String?
    @State private var pendingRenameAccount: SavedAccountSummary?
    @State private var renameText = ""
    @State private var showAppSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()
                titleSection
                Spacer()
                actionButtonsSection
            }
            // App-wide settings (Security incl. Child Mode, Appearance/Language/Currency,
            // Connection, Diagnostics) - reachable with NO account active, so a parent can
            // manage Child Mode without unlocking anything. Account-tier settings stay in
            // the in-account Settings sheet.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App Settings")
                }
            }
            .sheet(isPresented: $showAppSettings) {
                AppSettingsView()
            }
            .navigationDestination(isPresented: $showCreateWallet) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showImportWallet) {
                // Source-wallet chooser first (KasWare-style): the picked wallet decides the
                // identity derivation path family, then seed entry continues as before.
                ImportSourceWalletView()
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
                "Rename Account",
                isPresented: Binding(
                    get: { pendingRenameAccount != nil },
                    set: { if !$0 { pendingRenameAccount = nil } }
                )
            ) {
                TextField("Account name", text: $renameText)
                Button("Save") {
                    guard let account = pendingRenameAccount else { return }
                    walletManager.renameSavedAccount(account, to: renameText)
                    pendingRenameAccount = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRenameAccount = nil
                }
            } message: {
                Text("Enter a new name for this saved account.")
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

    private var titleSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("KaChat")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Secure messaging on Kaspa BlockDAG")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 16) {
            if !walletManager.savedAccounts.isEmpty {
                savedAccountsSection
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

    private var savedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved Accounts")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(walletManager.savedAccounts) { account in
                savedAccountRow(account)
            }
        }
    }

    private func savedAccountRow(_ account: SavedAccountSummary) -> some View {
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

            Menu {
                Button {
                    renameText = account.alias
                    pendingRenameAccount = account
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingRemovalAccount = account
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .tint(.accentColor)
            .disabled(signingInAccountId != nil || isRemovingAccount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func signIn(_ account: SavedAccountSummary) {
        guard signingInAccountId == nil, !isRemovingAccount else { return }
        signInErrorMessage = nil

        if settingsViewModel.settings.biometricAccountLoginEnabled {
            DeviceAuth.authenticate(reason: "Unlock to sign in to \(account.displayAlias)") {
                performSignIn(account)
            } onFailure: {
                signInErrorMessage = "Authentication failed."
            }
        } else {
            performSignIn(account)
        }
    }

    private func performSignIn(_ account: SavedAccountSummary) {
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
