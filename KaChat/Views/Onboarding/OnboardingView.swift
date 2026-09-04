import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showCreateWallet = false
    @State private var showImportWallet = false
    @State private var signingInAccountId: String?
    @State private var pendingRemovalAccount: SavedAccountSummary?
    /// The pencil's half sheet: Rename or Delete for one saved account.
    @State private var accountActionsTarget: SavedAccountSummary?
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
            .sheet(item: $accountActionsTarget) { account in
                accountActionsSheet(account)
            }
            .sheet(isPresented: Binding(
                get: { pendingRemovalAccount != nil },
                set: { if !$0 { pendingRemovalAccount = nil } }
            )) {
                if let account = pendingRemovalAccount {
                    ConfirmActionSheet(
                        title: "Remove Saved Account",
                        confirmTitle: "Remove from Device",
                        confirmSubtitle: "Deletes \(account.displayAlias) (\(account.shortPublicAddress)) and its local data from this device.",
                        confirmSystemImage: "trash"
                    ) {
                        removeSavedAccount(account)
                    }
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

    /// Rows are a fixed height, so five of them plus the gaps between is a height this can cap
    /// at - past that the list scrolls inside itself instead of pushing Create and Import off
    /// the bottom of the screen, which is what a dozen saved accounts used to do.
    private static let visibleSavedAccountRows = 5
    private static let savedAccountRowHeight: CGFloat = 64
    private static let savedAccountRowSpacing: CGFloat = 10

    private var savedAccountsSection: some View {
        let count = walletManager.savedAccounts.count
        let capped = min(count, Self.visibleSavedAccountRows)
        let maxHeight = CGFloat(capped) * Self.savedAccountRowHeight
            + CGFloat(max(capped - 1, 0)) * Self.savedAccountRowSpacing
        return VStack(alignment: .leading, spacing: 10) {
            Text("Saved Accounts")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: Self.savedAccountRowSpacing) {
                    ForEach(walletManager.savedAccounts) { account in
                        savedAccountRow(account)
                    }
                }
            }
            .frame(maxHeight: maxHeight)
            // Nothing to scroll at five or fewer, and leaving it enabled let the whole section
            // bounce against a page that does not move.
            .scrollDisabled(count <= Self.visibleSavedAccountRows)
        }
    }

    /// Rename or Delete for one saved account, behind the pencil.
    private func accountActionsSheet(_ account: SavedAccountSummary) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(account.displayAlias)
                    .font(.headline)
                Text(account.shortPublicAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetRow(
                title: "Rename",
                subtitle: "Gives this account a name of your own.",
                systemImage: "pencil"
            ) {
                accountActionsTarget = nil
                DispatchQueue.main.async {
                    renameText = account.alias
                    pendingRenameAccount = account
                }
            }
            ActionSheetRow(
                title: "Delete",
                subtitle: "Removes this account and its local data from this device.",
                systemImage: "trash",
                tint: .red
            ) {
                accountActionsTarget = nil
                DispatchQueue.main.async { pendingRemovalAccount = account }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
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

            // Half sheet rather than a context menu, like every other chooser in the app - and
            // Delete gets a line saying what it takes with it, which a menu of bare verbs cannot.
            Button {
                accountActionsTarget = account
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
