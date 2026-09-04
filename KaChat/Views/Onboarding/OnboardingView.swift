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
            // GeometryReader so the accounts list can be told a height that DEMONSTRABLY leaves
            // room for Create and Import. Sizing it off five rows alone pushed them off the
            // bottom of the screen on a short phone, and nothing here scrolls the page, so they
            // were simply unreachable.
            GeometryReader { proxy in
                VStack(spacing: hasSavedAccounts ? 20 : 40) {
                    Spacer(minLength: 0)
                    titleSection
                    Spacer(minLength: 0)
                    actionButtonsSection(availableHeight: proxy.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var hasSavedAccounts: Bool { !walletManager.savedAccounts.isEmpty }

    /// Wordmark with the app mark beside it, matching Android. The tagline is a welcome for a
    /// first run and drops once there are accounts to show - on a returning device it was part
    /// of why the list below had nowhere to go.
    private var titleSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("KaChat")
                    .font(.largeTitle.weight(.bold))
                Image("KaChatLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if !hasSavedAccounts {
                Text("Secure messaging on Kaspa BlockDAG")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func actionButtonsSection(availableHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            if hasSavedAccounts {
                savedAccountsSection(availableHeight: availableHeight)
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

    /// At most four rows, and never more than the page can spare - Create and Import have to
    /// stay on screen, and nothing here scrolls the page to reach them. The fifth account is
    /// where scrolling starts.
    private static let visibleSavedAccountRows = 4
    private static let savedAccountRowHeight: CGFloat = 64
    private static let savedAccountRowSpacing: CGFloat = 10

    private func savedAccountsSection(availableHeight: CGFloat) -> some View {
        let count = walletManager.savedAccounts.count
        let cappedRows = CGFloat(Self.visibleSavedAccountRows) * Self.savedAccountRowHeight
            + CGFloat(Self.visibleSavedAccountRows - 1) * Self.savedAccountRowSpacing
        // Everything else on this page - compact title, section header, both buttons and the
        // spacing around them. Whatever is left after that is what the list may take, floored at
        // two rows so it is always obviously a list.
        let reservedForRest: CGFloat = 300
        let twoRows = 2 * Self.savedAccountRowHeight + Self.savedAccountRowSpacing
        let spare = max(availableHeight - reservedForRest, twoRows)
        let listHeight = min(cappedRows, spare)
        let contentHeight = CGFloat(count) * Self.savedAccountRowHeight
            + CGFloat(max(count - 1, 0)) * Self.savedAccountRowSpacing
        let overflows = contentHeight > listHeight

        return VStack(alignment: .leading, spacing: 10) {
            Text("Saved Accounts")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if overflows {
                // A List, not a ScrollView. This is a column of Buttons, and in a ScrollView the
                // buttons won the drag: scrolling did nothing and the attempt registered as a tap
                // that signed you in. A List is a UICollectionView underneath and gets
                // scroll-versus-tap right, which is the whole reason to reach for one here.
                List {
                    ForEach(walletManager.savedAccounts) { account in
                        savedAccountRow(account)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Self.savedAccountRowSpacing, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: listHeight)
            } else {
                // Fits: no scroll container at all. One that cannot scroll still eats the drag.
                VStack(spacing: Self.savedAccountRowSpacing) {
                    ForEach(walletManager.savedAccounts) { account in
                        savedAccountRow(account)
                    }
                }
            }
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
        .frame(height: Self.savedAccountRowHeight)
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
