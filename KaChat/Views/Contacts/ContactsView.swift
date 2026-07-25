import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var editedAlias = ""
    @State private var aliasSaveTask: Task<Void, Never>?
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var giftAlreadyClaimedTapCount = 0
    @State private var isLoadingKNS = false
    @State private var knsDomains: [KNSDomain] = []
    @State private var knsPrimaryDomain: String?
    @State private var knsProfileInfo: KNSAddressProfileInfo?
    @State private var showMoreProfileInfo = false
    @State private var showChattingAddressOptions = false
    @State private var showWithdrawSheet = false
    @State private var spendingAddressBalanceSompi: UInt64?
    @State private var isLoadingSpendingBalance = false
    @State private var showSpendingAddressOptions = false
    @State private var showSpendingAddressWithdraw = false
    @State private var showAvatarPreview = false
    @State private var showKNSEditor = false
    @State private var showCreateKNSProfileFlow = false
    @State private var settingPrimaryDomainId: String?
    @State private var isSavingKNSProfile = false
    @State private var knsSaveProgressText: String?
    @State private var failedKNSUpdates: [KNSProfileFieldKey: String] = [:]
    @State private var showSettings = false
    @State private var isResolvingDonateAddress = false
    @State private var showLogoutConfirmation = false
    @State private var showWelcomeGuideReplay = false

    static func preloadQRCode(for address: String) {
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let wallet = walletManager.currentWallet {
                        accountNameCard(wallet)
                        if walletManager.showSetupGuides {
                            welcomeGuideSection
                        }
                        knsProfileSection
                        qrButtonsSection(wallet)
                        addressDropdownsSection(wallet)
                        aboutSection(wallet)
                        claimGiftSection
                        logOutSection
                    } else {
                        Text("No active account")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .refreshable {
                _ = try? await walletManager.refreshBalance()
                await loadSpendingAddressBalance()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel(Text("Settings"))
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showKNSEditor) {
                if let profileInfo = knsProfileInfo, profileInfo.assetId != nil {
                    KNSProfileEditorSheet(
                        profileInfo: profileInfo,
                        domains: knsDomains,
                        primaryDomain: knsPrimaryDomain,
                        settingPrimaryDomainId: settingPrimaryDomainId,
                        onSetPrimary: { domain in
                            Task {
                                await setPrimaryDomain(domain)
                            }
                        },
                        onInscribeComplete: { result in
                            Haptics.success()
                            showToast(localizedFormat("Inscribe submitted for %@.", result.domain))
                            Task {
                                await refreshKNSData(for: profileInfo.address)
                            }
                        },
                        onTransferComplete: { result in
                            Haptics.success()
                            let message = result.verified
                                ? localizedFormat("%@ transferred to %@.", result.domain, result.recipientAddress)
                                : localizedFormat("Transfer submitted for %@.", result.domain)
                            showToast(message)
                            Task {
                                await refreshKNSData(for: profileInfo.address)
                            }
                        },
                        onSetupGuideCompleted: {
                            Task {
                                await refreshKNSData(for: profileInfo.address)
                            }
                        }
                    ) { submission in
                        showKNSEditor = false
                        Task {
                            await saveKNSProfile(submission: submission, profileInfo: profileInfo)
                        }
                    }
                } else {
                    NavigationStack {
                        VStack(spacing: 12) {
                            Text("KNS profile unavailable.")
                                .foregroundColor(.secondary)
                            Button("Close") {
                                showKNSEditor = false
                            }
                        }
                        .padding()
                    }
                }
            }
            .sheet(isPresented: $showWithdrawSheet) {
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi)
                }
            }
            .sheet(isPresented: $showSpendingAddressWithdraw) {
                if let address = walletManager.currentSpendingAddress() {
                    SpendingAddressWithdrawView(
                        entry: SpendingAddressEntry(
                            index: walletManager.currentSpendingAddressIndex,
                            address: address,
                            balanceSompi: spendingAddressBalanceSompi ?? 0,
                            isCurrent: true
                        )
                    ) {
                        Task { await loadSpendingAddressBalance() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showAvatarPreview) {
                KNSAvatarFullscreenView(
                    avatarURLString: knsProfileInfo?.avatarURL,
                    fallbackText: editedAlias,
                    title: knsProfileInfo?.domainName ?? editedAlias
                )
            }
            .fullScreenCover(isPresented: $showWelcomeGuideReplay) {
                WelcomeGuideView(onFinished: { showWelcomeGuideReplay = false })
            }
            .fullScreenCover(isPresented: $showCreateKNSProfileFlow) {
                if let wallet = walletManager.currentWallet {
                    KNSCreateProfileFlowView(walletAddress: wallet.publicAddress, existingProfile: knsProfileInfo) {
                        showCreateKNSProfileFlow = false
                        Task {
                            // Wait out the fullScreenCover's dismiss transition before mutating
                            // knsProfileInfo - refreshing immediately can grow knsProfileCard
                            // (a new banner adds ~140pt) while the modal is still animating away,
                            // which can leave the presenting view's touch handling stuck so
                            // taps on it (e.g. the "Setup Guide" button) silently stop registering.
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            await refreshKNSData(for: wallet.publicAddress)
                        }
                    }
                }
            }
            .onAppear {
                if let wallet = walletManager.currentWallet {
                    editedAlias = wallet.alias
                    qrImage = ProfileQRCodeCache.cachedImage(for: wallet.publicAddress)
                    ProfileQRCodeCache.preload(address: wallet.publicAddress) { image in
                        self.qrImage = image
                    }
                }
                Task { _ = try? await walletManager.refreshBalance() }
                Task { await loadSpendingAddressBalance() }
                if let spendingAddress = walletManager.currentSpendingAddress() {
                    ProfileQRCodeCache.preload(address: spendingAddress, completion: nil)
                }
            }
            .task {
                guard let address = walletManager.currentWallet?.publicAddress else { return }
                let kns = KNSService.shared
                if let cached = kns.domainCache[address] {
                    knsDomains = cached.allDomains
                    knsPrimaryDomain = cached.primaryDomain
                }
                if let cachedProfile = kns.profileCache[address] {
                    knsProfileInfo = cachedProfile
                }
                if kns.domainCache[address] == nil || kns.profileCache[address] == nil {
                    isLoadingKNS = true
                }
                if let info = await kns.fetchInfo(for: address) {
                    knsDomains = info.allDomains
                    knsPrimaryDomain = info.primaryDomain
                }
                if let profileInfo = await kns.fetchProfile(for: address) {
                    knsProfileInfo = profileInfo
                }
                isLoadingKNS = false
            }
            .onChange(of: walletManager.currentWallet?.publicAddress) { newValue in
                guard let newValue else {
                    qrImage = nil
                    knsDomains = []
                    knsPrimaryDomain = nil
                    knsProfileInfo = nil
                    settingPrimaryDomainId = nil
                    return
                }
                qrImage = ProfileQRCodeCache.cachedImage(for: newValue)
                ProfileQRCodeCache.preload(address: newValue) { image in
                    self.qrImage = image
                }
            }
            .onChange(of: giftService.claimState) { newValue in
                if newValue != .alreadyClaimed {
                    giftAlreadyClaimedTapCount = 0
                }
            }
        }
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        return Text("\(exact) KAS")
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
            .onTapGesture {
                guard sompi != nil else { return }
                UIPasteboard.general.string = exact
                Haptics.success()
                showToast("Balance copied to clipboard.")
            }
    }

    /// Read-only display of which account is currently active. Renaming stays confined to
    /// the saved-accounts list in Onboarding (`walletManager.renameSavedAccount`) — this card
    /// is purely informative so there's no ambiguity about which account is signed in here.
    private func accountNameCard(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(wallet.alias)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassBackground(cornerRadius: 18))
    }

    /// Replays the same first-run walkthrough shown automatically after creating a brand-new
    /// wallet (`WelcomeGuideView`, triggered from `MainTabView` via
    /// `walletManager.justCreatedNewWallet`) - distinct `@State` name from `showSetupGuide` below,
    /// which re-launches the unrelated KNS domain/avatar creation wizard.
    private var welcomeGuideSection: some View {
        Button {
            showWelcomeGuideReplay = true
        } label: {
            HStack {
                Label("Welcome Guide", systemImage: "sparkles")
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(glassBackground(cornerRadius: 18))
    }

    private func accountNameSection(_ wallet: Wallet) -> some View {
        Section("Name") {
                TextField("Account name", text: $editedAlias)
                .onChange(of: editedAlias) { newValue in
                    scheduleAliasSave(newValue, previousAlias: wallet.alias)
                }
        }
    }

    private func setPrimaryDomain(_ domain: KNSDomain) async {
        guard settingPrimaryDomainId == nil else { return }
        guard let walletAddress = walletManager.currentWallet?.publicAddress else {
            await MainActor.run {
                showToast(localized("Wallet not available."), style: .error)
            }
            return
        }

        let assetId = domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty else {
            await MainActor.run {
                showToast(localized("KNS domain id is missing."), style: .error)
            }
            return
        }

        await MainActor.run {
            settingPrimaryDomainId = assetId
        }
        logKNSWrite("SET_PRIMARY_START domain=\(domain.fullName) asset=\(assetId)")

        do {
            try await submitSetPrimaryDomainWithSignatureFallback(domainId: assetId)
            await MainActor.run {
                knsPrimaryDomain = domain.fullName
            }
            await refreshKNSData(for: walletAddress)
            await MainActor.run {
                settingPrimaryDomainId = nil
                Haptics.success()
                showToast(localizedFormat("Primary domain set to %@.", domain.fullName))
            }
            logKNSWrite("SET_PRIMARY_SUCCESS domain=\(domain.fullName)")
        } catch {
            logKNSWrite("SET_PRIMARY_FAIL domain=\(domain.fullName) \(diagnosticError(error))")
            let message = compactErrorText(error)
            await MainActor.run {
                settingPrimaryDomainId = nil
                Haptics.impact(.medium)
                showToast(localizedFormat("Set primary failed: %@", message), style: .error)
            }
        }
    }

    private func refreshKNSData(for address: String) async {
        await MainActor.run {
            isLoadingKNS = true
        }
        if let info = await KNSService.shared.fetchInfo(for: address) {
            await MainActor.run {
                knsDomains = info.allDomains
                knsPrimaryDomain = info.primaryDomain
            }
        }
        if let profileInfo = await KNSService.shared.fetchProfile(for: address) {
            await MainActor.run {
                knsProfileInfo = profileInfo
            }
        }
        await MainActor.run {
            isLoadingKNS = false
        }
    }

    @ViewBuilder
    private var knsProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("KNS Profile")
            if isLoadingKNS && knsProfileInfo == nil {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading profile...")
                        .foregroundColor(.secondary)
                }
            } else if let profileInfo = knsProfileInfo {
                knsProfileCard(profileInfo)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
    }

    private func knsProfileCard(_ profileInfo: KNSAddressProfileInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if KNSProfileLinkBuilder.websiteURL(from: profileInfo.profile?.bannerUrl) != nil {
                KNSBannerImageView(
                    bannerURLString: profileInfo.profile?.bannerUrl,
                    height: 140,
                    cornerRadius: 0
                )
            }

            knsProfileHeaderRow(profileInfo)

            if isSavingKNSProfile, let progress = knsSaveProgressText {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text(progress)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if let assetId = profileInfo.assetId,
               !assetId.isEmpty,
               !failedKNSUpdates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Failed updates")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(failedKNSUpdates.keys.sorted(by: { $0.displayName < $1.displayName }), id: \.self) { key in
                        let value = failedKNSUpdates[key] ?? ""
                        Button {
                            Task {
                                await retryFailedKNSField(
                                    key: key,
                                    value: value,
                                    assetId: assetId,
                                    domainName: profileInfo.domainName
                                )
                            }
                        } label: {
                            HStack {
                                Text(localizedFormat("Retry %@", key.displayName))
                                Spacer()
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .disabled(isSavingKNSProfile)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if hasMoreProfileInfo(profileInfo) {
                Divider()
                    .padding(.leading, 16)

                DisclosureGroup(isExpanded: $showMoreProfileInfo) {
                    moreInfoRows(profileInfo)
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                } label: {
                    Text("More Info")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                }
                .tint(.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        // Clip after background (not before) so the banner's square image corners are
        // trimmed to match the card's rounded top corners, then apply the shadow last so
        // it isn't clipped away along with the banner overflow.
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private func knsProfileHeaderRow(_ profileInfo: KNSAddressProfileInfo) -> some View {
        let hasDomain = !(profileInfo.domainName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            if hasDomain {
                showKNSEditor = true
            } else {
                showCreateKNSProfileFlow = true
            }
        } label: {
            if hasDomain {
                HStack(spacing: 12) {
                    KNSAvatarView(
                        avatarURLString: profileInfo.avatarURL,
                        fallbackText: editedAlias,
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        if let domainName = profileInfo.domainName, !domainName.isEmpty {
                            Text(domainName)
                                .font(.headline)
                                .foregroundColor(.primary)
                        }
                        if let bio = profileInfo.profile?.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            } else {
                // No domain yet - nothing to show an avatar/chevron-row for (there's no
                // profile data at all), so this collapses to a single centered call-to-action
                // that opens the guided creation wizard instead of the editor built for
                // *existing* profiles (which would silently show nothing - see showKNSEditor's
                // `profileInfo.assetId != nil` guard).
                Text("Create KNS Profile")
                    .font(.headline)
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(16)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Narrow gate for the collapsible "More Info" section — deliberately excludes
    /// avatarUrl/bannerUrl since those are already shown elsewhere in the card.
    private func hasMoreProfileInfo(_ profileInfo: KNSAddressProfileInfo) -> Bool {
        guard let profile = profileInfo.profile else { return false }
        return [profile.x, profile.website, profile.telegram, profile.discord, profile.contactEmail, profile.github, profile.redirectUrl]
            .contains { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @ViewBuilder
    private func moreInfoRows(_ profileInfo: KNSAddressProfileInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let x = profileInfo.profile?.x, !x.isEmpty {
                LabeledContent("X") {
                    profileLinkView(text: x, url: KNSProfileLinkBuilder.xURL(from: x), fieldName: "X")
                }
            }
            if let website = profileInfo.profile?.website, !website.isEmpty {
                LabeledContent("Website") {
                    profileLinkView(text: website, url: KNSProfileLinkBuilder.websiteURL(from: website), fieldName: "Website")
                }
            }
            if let telegram = profileInfo.profile?.telegram, !telegram.isEmpty {
                LabeledContent("Telegram") {
                    profileLinkView(text: telegram, url: KNSProfileLinkBuilder.telegramURL(from: telegram), fieldName: "Telegram")
                }
            }
            if let discord = profileInfo.profile?.discord, !discord.isEmpty {
                LabeledContent("Discord") {
                    profileLinkView(text: discord, url: KNSProfileLinkBuilder.discordURL(from: discord), fieldName: "Discord")
                }
            }
            if let contactEmail = profileInfo.profile?.contactEmail, !contactEmail.isEmpty {
                LabeledContent("Email") {
                    profileLinkView(text: contactEmail, url: KNSProfileLinkBuilder.emailURL(from: contactEmail), fieldName: "Email")
                }
            }
            if let github = profileInfo.profile?.github, !github.isEmpty {
                LabeledContent("GitHub") {
                    profileLinkView(text: github, url: KNSProfileLinkBuilder.githubURL(from: github), fieldName: "GitHub")
                }
            }
            if let redirectUrl = profileInfo.profile?.redirectUrl, !redirectUrl.isEmpty {
                LabeledContent("Redirect") {
                    profileLinkView(text: redirectUrl, url: KNSProfileLinkBuilder.websiteURL(from: redirectUrl), fieldName: "Redirect")
                }
            }
        }
    }

    // MARK: - QR buttons row (Accept Kaspa / Chatting Address)

    private func qrButtonsSection(_ wallet: Wallet) -> some View {
        HStack(spacing: 24) {
            Spacer()
            NavigationLink {
                ChattingAddressQRView(
                    address: walletManager.currentSpendingAddress() ?? wallet.publicAddress,
                    balanceSompi: spendingAddressBalanceSompi,
                    subtitle: "Share this address to receive Kaspa payments."
                )
            } label: {
                VStack(spacing: 8) {
                    qrCircleIcon
                    Text("Receive Kaspa")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            NavigationLink {
                ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
            } label: {
                VStack(spacing: 8) {
                    qrCircleIcon
                    Text("Chatting Address")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var qrCircleIcon: some View {
        Image(systemName: "qrcode")
            .font(.system(size: 26, weight: .medium))
            .foregroundColor(.black)
            .frame(width: 80, height: 80)
            .background(Circle().fill(Color.accentColor))
    }

    // MARK: - Address dropdown rows (Chatting Address / Spending Address)

    private func addressDropdownsSection(_ wallet: Wallet) -> some View {
        VStack(spacing: 12) {
            chattingAddressDropdown(wallet)
            spendingAddressRow()
        }
    }

    private func spendingAddressRow() -> some View {
        VStack(spacing: 0) {
            Button {
                Haptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSpendingAddressOptions.toggle()
                }
            } label: {
                HStack {
                    Text("Spending Address")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer()
                    if isLoadingSpendingBalance {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Text(spendingAddressBalanceSompi.map { "\(formatKaspaExact($0)) KAS" } ?? "—")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                    }
                    Image(systemName: showSpendingAddressOptions ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSpendingAddressOptions {
                Divider()
                    .padding(.leading, 16)
                Button {
                    guard let address = walletManager.currentSpendingAddress() else { return }
                    UIPasteboard.general.string = address
                    Haptics.success()
                    showToast("Address copied to clipboard.")
                } label: {
                    HStack {
                        Text("Copy Address")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 16)
                Button {
                    showSpendingAddressWithdraw = true
                } label: {
                    HStack {
                        Text("Send Kaspa")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 16)
                NavigationLink {
                    ManageAddressesView()
                } label: {
                    HStack {
                        Text("Manage Addresses")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(glassBackground(cornerRadius: 18))
    }

    private func loadSpendingAddressBalance() async {
        guard let address = walletManager.currentSpendingAddress() else { return }
        isLoadingSpendingBalance = true
        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
        spendingAddressBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        isLoadingSpendingBalance = false
    }

    private func chattingAddressDropdown(_ wallet: Wallet) -> some View {
        VStack(spacing: 0) {
            Button {
                Haptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showChattingAddressOptions.toggle()
                }
            } label: {
                HStack {
                    Text("Chatting Address")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(wallet.balanceSompi.map { "\(formatKaspaExact($0)) KAS" } ?? "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                    Image(systemName: showChattingAddressOptions ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showChattingAddressOptions {
                Divider()
                    .padding(.leading, 16)
                Button {
                    UIPasteboard.general.string = wallet.publicAddress
                    Haptics.success()
                    showToast("Address copied to clipboard.")
                } label: {
                    HStack {
                        Text("Copy Address")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 16)
                Button {
                    showWithdrawSheet = true
                } label: {
                    HStack {
                        Text("Withdraw Kaspa")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 16)
                NavigationLink {
                    ChattingAddressTransactionHistoryView(address: wallet.publicAddress)
                } label: {
                    HStack {
                        Text("Transaction History")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(glassBackground(cornerRadius: 18))
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    /// Single row above Log Out instead of a whole card section that used to disappear once
    /// claimed/unavailable (or entirely once balance was non-zero) - always visible now, matching
    /// the Welcome Guide funding step's version of this same `GiftService.shared` state machine:
    /// tappable while `.eligible`, grayed out with a relabel otherwise. The `.alreadyClaimed`
    /// case keeps the hidden 10-tap reset gesture the old card had (support/debug tool) - the
    /// button itself is never `.disabled()` so that gesture keeps registering even when the
    /// primary claim action is a no-op.
    private var claimGiftSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                switch giftService.claimState {
                case .eligible:
                    guard let address = walletManager.currentWallet?.publicAddress else { return }
                    Task { await giftService.claimGift(walletAddress: address) }
                case .alreadyClaimed:
                    giftAlreadyClaimedTapCount += 1
                    guard giftAlreadyClaimedTapCount >= 10 else { return }
                    giftAlreadyClaimedTapCount = 0
                    giftService.resetClaimStateForRetry()
                    Haptics.success()
                    showToast("Gift claim reset. You can request it again.")
                default:
                    break
                }
            } label: {
                HStack {
                    Text(giftRowTitle)
                        .foregroundColor(isGiftClaimable ? .primary : .secondary)
                    Spacer()
                    if giftService.claimState == .claiming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isGiftClaimable ? "gift.fill" : "gift")
                            .foregroundColor(isGiftClaimable ? .accentColor : .secondary)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(glassBackground(cornerRadius: 18))

            if case .unavailable(let reason) = giftService.claimState {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var isGiftClaimable: Bool {
        giftService.claimState == .eligible
    }

    private var giftRowTitle: String {
        switch giftService.claimState {
        case .checking, .eligible:
            return "Claim Gift"
        case .claiming:
            return "Claiming gift..."
        case .claimed:
            return "Gift claimed"
        case .alreadyClaimed:
            return "Gift already claimed"
        case .unavailable:
            return "Gift unavailable"
        }
    }

    private func accountAddressSection(_ wallet: Wallet) -> some View {
        Section("Address") {
            VStack(alignment: .leading, spacing: 8) {
                if let qrImage {
                    HStack {
                        Spacer()
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 100, maxHeight: 100)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Spacer()
                    }
                    Text("Scan to share account. Tap anywhere here to copy address.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(wallet.publicAddress)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                UIPasteboard.general.string = wallet.publicAddress
                Haptics.success()
                showToast("Address copied to clipboard.")
            }
        }
    }

    private func accountBalanceSection(_ wallet: Wallet) -> some View {
        Section("Balance") {
            if let balance = wallet.balanceSompi {
                let exact = formatKaspaExact(balance)
                Button {
                    UIPasteboard.general.string = exact
                    Haptics.success()
                    showToast("Balance copied to clipboard.")
                } label: {
                    HStack {
                        ShimmeringText(
                            text: "\(exact) KAS",
                            font: .system(.body, design: .monospaced),
                            color: .primary,
                            isShimmering: walletManager.isBalanceRefreshing
                        )
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.accentColor)
                    }
                }
            } else {
                Text("—")
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Bottom-most section on Profile - merges what used to be a separate "Info" section
    /// (just "Created") with Settings' old "About" section (Version/Website/Support Email/
    /// Donate), now reached without needing to open Settings at all.
    private func aboutSection(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")
            VStack(spacing: 0) {
                HStack {
                    Text("Created")
                    Spacer()
                    Text(formatDate(wallet.createdAt))
                        .foregroundColor(.secondary)
                }
                .padding(16)

                Divider().padding(.leading, 16)
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersionDisplay)
                        .foregroundColor(.secondary)
                }
                .padding(16)

                Divider().padding(.leading, 16)
                Link(destination: websiteURL) {
                    HStack {
                        Text("Website")
                            .foregroundColor(.primary)
                        Spacer()
                        Text("linktr.ee/Kachat_")
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }

                Divider().padding(.leading, 16)
                Link(destination: supportEmailURL) {
                    HStack {
                        Text("Support Email")
                            .foregroundColor(.primary)
                        Spacer()
                        Text("kaspasilver@gmail.com")
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }

                Divider().padding(.leading, 16)
                Button {
                    Task {
                        await donate()
                    }
                } label: {
                    HStack {
                        Text("Donate")
                            .foregroundColor(.primary)
                        Spacer()
                        if isResolvingDonateAddress {
                            ProgressView()
                        } else {
                            Text("kachat.kas")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isResolvingDonateAddress)
            }
            .background(glassBackground(cornerRadius: 18))
        }
    }

    /// Moved here from Settings > Actions - Profile is where the rest of the account-level
    /// actions (address management, About) already live, so Log Out belongs alongside them
    /// rather than buried in Settings.
    private var logOutSection: some View {
        Button(role: .destructive) {
            showLogoutConfirmation = true
        } label: {
            HStack {
                Text("Log Out")
                    .foregroundColor(.red)
                Spacer()
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .foregroundColor(.red)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(glassBackground(cornerRadius: 18))
        .confirmationDialog(
            "Log Out",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                Task {
                    await walletManager.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out of your account, but keeps local wallet and message data on this device.")
        }
    }

    /// Resolves the KNS domain "kachat.kas" to its owner address and jumps straight to that
    /// chat in payment mode, ready to send - matches the Android client's About screen Donate row.
    private func donate() async {
        if isResolvingDonateAddress { return }
        isResolvingDonateAddress = true
        defer { isResolvingDonateAddress = false }

        guard let resolution = await KNSService.shared.resolveDomain("kachat.kas") else {
            showToast("Couldn't resolve kachat.kas. Please try again later.", style: .error)
            return
        }

        let contact = contactsManager.getOrCreateContact(address: resolution.ownerAddress, alias: resolution.domain)
        _ = chatService.getOrCreateConversation(for: contact)
        NotificationCenter.default.post(
            name: .openChat,
            object: nil,
            userInfo: ["contactAddress": contact.address, "paymentMode": true]
        )
    }

    private var appVersionDisplay: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (version?.trimmingCharacters(in: .whitespacesAndNewlines), build?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case let (v?, b?) where !v.isEmpty && !b.isEmpty:
            return "\(v) (\(b))"
        case let (v?, _) where !v.isEmpty:
            return v
        case let (_, b?) where !b.isEmpty:
            return b
        default:
            return "Unknown"
        }
    }

    private var websiteURL: URL {
        URL(string: "https://linktr.ee/Kachat_")!
    }

    private var supportEmailURL: URL {
        URL(string: "mailto:kaspasilver@gmail.com")!
    }

    private func scheduleAliasSave(_ rawAlias: String, previousAlias: String) {
        aliasSaveTask?.cancel()
        let trimmed = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != previousAlias else { return }

        aliasSaveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            guard walletManager.currentWallet?.alias != trimmed else { return }
            try? await walletManager.updateAlias(trimmed)
            await MainActor.run {
                showToast("Name updated.")
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }

    private func formatDate(_ date: Date) -> String {
        SharedFormatting.mediumDateShortTime.string(from: date)
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

    @ViewBuilder
    private func profileLinkView(text: String, url: URL?, fieldName: String) -> some View {
        if let url {
            Link(text, destination: url)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        copyProfileFieldValue(text, fieldName: fieldName)
                    }
                )
        } else {
            Text(text)
                .foregroundColor(.secondary)
                .onLongPressGesture(minimumDuration: 0.45) {
                    copyProfileFieldValue(text, fieldName: fieldName)
                }
        }
    }

    private func copyProfileFieldValue(_ value: String, fieldName: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        showToast(localizedFormat("%@ copied to clipboard.", fieldName))
    }

    private func logKNSWrite(_ message: String) {
        AppLog.log("[KNS_WRITE_UI] %@", message)
    }

    private func diagnosticError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = [
            "type=\(String(describing: type(of: error)))",
            "message=\(error.localizedDescription)",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code):\(underlying.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    private func compactErrorText(_ error: Error, maxLength: Int = 160) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }

    private func saveKNSProfile(
        submission: KNSProfileEditorSubmission,
        profileInfo: KNSAddressProfileInfo
    ) async {
        guard let walletAddress = walletManager.currentWallet?.publicAddress else {
            await MainActor.run {
                showToast(localized("Wallet not available."), style: .error)
            }
            return
        }
        guard let assetId = profileInfo.assetId, !assetId.isEmpty else {
            await MainActor.run {
                showToast(localized("KNS asset id is missing."), style: .error)
            }
            return
        }

        await MainActor.run {
            isSavingKNSProfile = true
            knsSaveProgressText = localized("Preparing profile update...")
            failedKNSUpdates = [:]
        }
        logKNSWrite("SAVE_START address=\(walletAddress) asset=\(assetId)")

        var values = submission.fieldValues()

        do {
            // Upload picked avatar/banner first; resulting URLs are written on-chain.
            if let avatarData = submission.avatarUploadData {
                logKNSWrite("UPLOAD_AVATAR_START bytes=\(avatarData.count)")
                await MainActor.run {
                    knsSaveProgressText = localized("Uploading avatar...")
                }
                let uploadedURL = try await uploadProfileImageWithSignatureFallback(
                    assetId: assetId,
                    uploadType: .avatar,
                    imageData: avatarData,
                    mimeType: submission.avatarUploadMimeType ?? "image/jpeg"
                )
                values[.avatarUrl] = uploadedURL
                logKNSWrite("UPLOAD_AVATAR_OK url=\(uploadedURL)")
            }

            if let bannerData = submission.bannerUploadData {
                logKNSWrite("UPLOAD_BANNER_START bytes=\(bannerData.count)")
                await MainActor.run {
                    knsSaveProgressText = localized("Uploading banner...")
                }
                let uploadedURL = try await uploadProfileImageWithSignatureFallback(
                    assetId: assetId,
                    uploadType: .banner,
                    imageData: bannerData,
                    mimeType: submission.bannerUploadMimeType ?? "image/jpeg"
                )
                values[.bannerUrl] = uploadedURL
                logKNSWrite("UPLOAD_BANNER_OK url=\(uploadedURL)")
            }

            let original = profileInfo.profile ?? .empty
            let orderedKeys: [KNSProfileFieldKey] = [
                .avatarUrl, .bannerUrl, .bio, .x, .website,
                .telegram, .discord, .contactEmail, .github, .redirectUrl
            ]

            var changes: [(key: KNSProfileFieldKey, value: String)] = []
            for key in orderedKeys {
                let target = values[key] ?? ""
                let current = (original.value(for: key) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if target != current {
                    changes.append((key: key, value: target))
                }
            }

            guard !changes.isEmpty else {
                logKNSWrite("SAVE_NO_CHANGES")
                await MainActor.run {
                    isSavingKNSProfile = false
                    knsSaveProgressText = nil
                    showToast(localized("No KNS profile changes detected."))
                }
                return
            }

            var successCount = 0
            var failedFields: [String] = []
            var failedChanges: [KNSProfileFieldKey: String] = [:]
            var failedMessages: [KNSProfileFieldKey: String] = [:]
            var primaryPromotionFailure: String?

            for change in changes {
                try validateKNSFieldValue(change.value, key: change.key, assetId: assetId)
            }
            logKNSWrite("SAVE_CHANGES count=\(changes.count) keys=\(changes.map { $0.key.rawValue }.joined(separator: ","))")

            for (index, change) in changes.enumerated() {
                await MainActor.run {
                    knsSaveProgressText = localizedFormat(
                        "Updating %@ (%d/%d)...",
                        change.key.displayName,
                        index + 1,
                        changes.count
                    )
                }
                logKNSWrite("FIELD_START key=\(change.key.rawValue) valueLen=\(change.value.count) index=\(index + 1)/\(changes.count)")
                do {
                    _ = try await KNSProfileWriteService.shared.submitAddProfile(
                        assetId: assetId,
                        key: change.key,
                        value: change.value,
                        domainName: profileInfo.domainName
                    )
                    successCount += 1
                    logKNSWrite("FIELD_OK key=\(change.key.rawValue)")
                } catch {
                    failedFields.append(change.key.displayName)
                    failedChanges[change.key] = change.value
                    let message = compactErrorText(error)
                    failedMessages[change.key] = message
                    logKNSWrite("FIELD_FAIL key=\(change.key.rawValue) \(diagnosticError(error))")
                }
            }

            if successCount > 0 {
                switch await promoteEditedDomainToPrimaryIfNeeded(
                    walletAddress: walletAddress,
                    editedAssetId: assetId
                ) {
                case .notNeeded, .success:
                    break
                case .failed(let message):
                    primaryPromotionFailure = message
                }
            }

            if let refreshed = await KNSService.shared.fetchProfile(for: walletAddress) {
                await MainActor.run {
                    knsProfileInfo = refreshed
                }
            }

            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                failedKNSUpdates = failedChanges
                if successCount == changes.count {
                    logKNSWrite("SAVE_SUCCESS count=\(successCount)")
                    if let primaryPromotionFailure, !primaryPromotionFailure.isEmpty {
                        Haptics.impact(.medium)
                        showToast(localizedFormat("Set primary failed: %@", primaryPromotionFailure), style: .error)
                    } else {
                        Haptics.success()
                        showToast(localized("KNS profile updated."))
                    }
                } else if successCount > 0 {
                    logKNSWrite("SAVE_PARTIAL success=\(successCount) failed=\(changes.count - successCount)")
                    Haptics.impact(.medium)
                    let failedList = failedFields.joined(separator: ", ")
                    let firstReason = failedMessages.values.first ?? primaryPromotionFailure ?? ""
                    if firstReason.isEmpty {
                        showToast(
                            localizedFormat(
                                "Updated %d/%d. Failed: %@.",
                                successCount,
                                changes.count,
                                failedList
                            ),
                            style: .error
                        )
                    } else {
                        showToast(
                            localizedFormat(
                                "Updated %d/%d. Failed: %@. %@",
                                successCount,
                                changes.count,
                                failedList,
                                firstReason
                            ),
                            style: .error
                        )
                    }
                } else {
                    logKNSWrite("SAVE_FAILED count=\(changes.count)")
                    Haptics.impact(.medium)
                    let firstReason = failedMessages.values.first ?? ""
                    if firstReason.isEmpty {
                        showToast(localized("KNS profile update failed."), style: .error)
                    } else {
                        showToast(localizedFormat("KNS profile update failed: %@", firstReason), style: .error)
                    }
                }
            }
        } catch {
            logKNSWrite("SAVE_ABORT \(diagnosticError(error))")
            let message = compactErrorText(error)
            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                Haptics.impact(.medium)
                showToast(localizedFormat("KNS profile update failed: %@", message), style: .error)
            }
        }
    }

    private enum KNSPrimaryPromotionResult {
        case notNeeded
        case success
        case failed(String)
    }

    private func promoteEditedDomainToPrimaryIfNeeded(
        walletAddress: String,
        editedAssetId rawEditedAssetId: String
    ) async -> KNSPrimaryPromotionResult {
        let editedAssetId = rawEditedAssetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedAssetId.isEmpty else {
            return .notNeeded
        }

        guard let info = await KNSService.shared.fetchInfo(for: walletAddress) else {
            return .notNeeded
        }
        guard info.primaryDomain == nil else {
            return .notNeeded
        }

        guard let selectedFallbackDomain = info.allDomains.first(where: {
            $0.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines) == editedAssetId
        }) else {
            return .notNeeded
        }

        logKNSWrite("AUTO_PRIMARY_START domain=\(selectedFallbackDomain.fullName) asset=\(editedAssetId)")
        do {
            try await submitSetPrimaryDomainWithSignatureFallback(domainId: editedAssetId)
            if let refreshedInfo = await KNSService.shared.fetchInfo(for: walletAddress) {
                await MainActor.run {
                    knsPrimaryDomain = refreshedInfo.primaryDomain ?? selectedFallbackDomain.fullName
                    knsDomains = refreshedInfo.allDomains
                }
            } else {
                await MainActor.run {
                    knsPrimaryDomain = selectedFallbackDomain.fullName
                }
            }
            logKNSWrite("AUTO_PRIMARY_SUCCESS domain=\(selectedFallbackDomain.fullName)")
            return .success
        } catch {
            let message = compactErrorText(error)
            logKNSWrite("AUTO_PRIMARY_FAIL domain=\(selectedFallbackDomain.fullName) \(diagnosticError(error))")
            return .failed(message)
        }
    }

    private func uploadProfileImageWithSignatureFallback(
        assetId: String,
        uploadType: KNSProfileImageUploadType,
        imageData: Data,
        mimeType: String
    ) async throws -> String {
        let signMessage = try KNSService.shared.buildImageUploadSigningMessage(
            assetId: assetId,
            uploadType: uploadType
        )

        let signingModes: [(WalletManager.ArbitraryMessageSigningMode, String)] = [
            (.kaspaPersonalMessage, "kaspaPersonalMessage"),
            (.rawUTF8, "rawUTF8"),
            (.sha256Digest, "sha256Digest")
        ]

        var lastError: Error?
        for (index, entry) in signingModes.enumerated() {
            let signature = try walletManager.signArbitraryMessage(
                signMessage,
                mode: entry.0
            )
            logKNSWrite("UPLOAD_SIGN mode=\(entry.1) sigLen=\(signature.count) type=\(uploadType.rawValue)")
            do {
                return try await KNSService.shared.uploadProfileImage(
                    assetId: assetId,
                    uploadType: uploadType,
                    imageData: imageData,
                    mimeType: mimeType,
                    signMessage: signMessage,
                    signature: signature
                )
            } catch {
                lastError = error
                let hasNextMode = index < (signingModes.count - 1)
                guard hasNextMode, isSignatureVerificationFailure(error) else {
                    throw error
                }
                let nextModeName = signingModes[index + 1].1
                logKNSWrite("UPLOAD_RETRY mode=\(nextModeName) type=\(uploadType.rawValue)")
            }
        }

        if let lastError {
            throw lastError
        }
        throw KasiaError.apiError("KNS image upload failed")
    }

    private func submitSetPrimaryDomainWithSignatureFallback(domainId: String) async throws {
        let signMessage = try KNSService.shared.buildPrimaryNameSigningMessage(domainId: domainId)

        let signingModes: [(WalletManager.ArbitraryMessageSigningMode, String)] = [
            (.kaspaPersonalMessage, "kaspaPersonalMessage"),
            (.rawUTF8, "rawUTF8"),
            (.sha256Digest, "sha256Digest")
        ]

        var lastError: Error?
        for (index, entry) in signingModes.enumerated() {
            let signature = try walletManager.signArbitraryMessage(
                signMessage,
                mode: entry.0
            )
            logKNSWrite("SET_PRIMARY_SIGN mode=\(entry.1) sigLen=\(signature.count) asset=\(domainId)")
            do {
                _ = try await KNSService.shared.setPrimaryDomain(
                    signMessage: signMessage,
                    signature: signature
                )
                return
            } catch {
                lastError = error
                let hasNextMode = index < (signingModes.count - 1)
                guard hasNextMode, isSignatureVerificationFailure(error) else {
                    throw error
                }
                let nextModeName = signingModes[index + 1].1
                logKNSWrite("SET_PRIMARY_RETRY mode=\(nextModeName) asset=\(domainId)")
            }
        }

        if let lastError {
            throw lastError
        }
        throw KasiaError.apiError("KNS primary domain update failed")
    }

    private func isSignatureVerificationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("signature verification failed")
            || message.contains("unauthorized")
    }

    private func isLikelyValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2 else { return false }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[1].contains(".")
    }

    private func retryFailedKNSField(
        key: KNSProfileFieldKey,
        value: String,
        assetId: String,
        domainName: String?
    ) async {
        guard !isSavingKNSProfile else { return }

        do {
            logKNSWrite("RETRY_START key=\(key.rawValue)")
            try validateKNSFieldValue(value, key: key, assetId: assetId)
            await MainActor.run {
                isSavingKNSProfile = true
                knsSaveProgressText = localizedFormat("Retrying %@...", key.displayName)
            }

            _ = try await KNSProfileWriteService.shared.submitAddProfile(
                assetId: assetId,
                key: key,
                value: value,
                domainName: domainName
            )

            if let walletAddress = walletManager.currentWallet?.publicAddress,
               let refreshed = await KNSService.shared.fetchProfile(for: walletAddress) {
                await MainActor.run {
                    knsProfileInfo = refreshed
                }
            }

            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                failedKNSUpdates.removeValue(forKey: key)
                Haptics.success()
                showToast(localizedFormat("%@ updated.", key.displayName))
            }
            logKNSWrite("RETRY_OK key=\(key.rawValue)")
        } catch {
            logKNSWrite("RETRY_FAIL key=\(key.rawValue) \(diagnosticError(error))")
            let message = compactErrorText(error)
            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                Haptics.impact(.medium)
                showToast(localizedFormat("Retry failed: %@", message), style: .error)
            }
        }
    }

    private func validateKNSFieldValue(
        _ value: String,
        key: KNSProfileFieldKey,
        assetId: String
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let maxLength: Int
        switch key {
        case .bio:
            maxLength = 300
        case .contactEmail:
            maxLength = 254
        case .x, .telegram, .github:
            maxLength = 64
        case .discord:
            maxLength = 128
        case .website, .redirectUrl, .avatarUrl, .bannerUrl:
            maxLength = 2048
        }

        if trimmed.count > maxLength {
            throw KasiaError.apiError("\(key.displayName) is too long (\(trimmed.count)/\(maxLength))")
        }

        switch key {
        case .contactEmail:
            if !trimmed.isEmpty && !isLikelyValidEmail(trimmed) {
                throw KasiaError.apiError("Invalid email address format")
            }
        case .discord:
            if !trimmed.isEmpty && KNSProfileLinkBuilder.discordURL(from: trimmed) == nil {
                throw KasiaError.apiError("Discord must be a numeric user id or a valid /users/<id> URL")
            }
        default:
            break
        }

        let payload = KNSService.shared.buildAddProfilePayload(
            assetId: assetId,
            key: key,
            value: trimmed
        )
        let payloadJSON = try JSONEncoder().encode(payload)
        if payloadJSON.count > 520 {
            throw KasiaError.apiError("\(key.displayName) is too long for KNS inscription payload")
        }
    }

}

private struct KNSProfileEditorSubmission {
    let avatarUrl: String
    let bannerUrl: String
    let bio: String
    let x: String
    let website: String
    let telegram: String
    let discord: String
    let contactEmail: String
    let github: String
    let redirectUrl: String
    let avatarUploadData: Data?
    let avatarUploadMimeType: String?
    let bannerUploadData: Data?
    let bannerUploadMimeType: String?

    func fieldValues() -> [KNSProfileFieldKey: String] {
        [
            .avatarUrl: normalizedValue(avatarUrl),
            .bannerUrl: normalizedValue(bannerUrl),
            .bio: normalizedValue(bio),
            .x: normalizedValue(x),
            .website: normalizedValue(website),
            .telegram: normalizedValue(telegram),
            .discord: normalizedValue(discord),
            .contactEmail: normalizedValue(contactEmail),
            .github: normalizedValue(github),
            .redirectUrl: normalizedValue(redirectUrl)
        ]
    }

    private func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct KNSProfileEditorSheet: View {
    let profileInfo: KNSAddressProfileInfo
    let onSave: (KNSProfileEditorSubmission) -> Void
    let domains: [KNSDomain]
    let primaryDomain: String?
    let settingPrimaryDomainId: String?
    let onSetPrimary: (KNSDomain) -> Void
    let onInscribeComplete: (KNSDomainInscribeResult) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    let onSetupGuideCompleted: () -> Void

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @State private var showSetupGuide = false

    @State private var avatarUrl: String
    @State private var bannerUrl: String
    @State private var bio: String
    @State private var x: String
    @State private var website: String
    @State private var telegram: String
    @State private var discord: String
    @State private var contactEmail: String
    @State private var github: String
    @State private var redirectUrl: String

    @State private var avatarUploadData: Data?
    @State private var avatarUploadMimeType: String?
    @State private var bannerUploadData: Data?
    @State private var bannerUploadMimeType: String?

    @State private var avatarPreviewImage: UIImage?
    @State private var bannerPreviewImage: UIImage?
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var bannerPickerItem: PhotosPickerItem?
    @State private var isLoadingAvatar = false
    @State private var isLoadingBanner = false
    @State private var imageLoadError: String?

    init(
        profileInfo: KNSAddressProfileInfo,
        domains: [KNSDomain],
        primaryDomain: String?,
        settingPrimaryDomainId: String?,
        onSetPrimary: @escaping (KNSDomain) -> Void,
        onInscribeComplete: @escaping (KNSDomainInscribeResult) -> Void,
        onTransferComplete: @escaping (KNSDomainTransferResult) -> Void,
        onSetupGuideCompleted: @escaping () -> Void,
        onSave: @escaping (KNSProfileEditorSubmission) -> Void
    ) {
        self.profileInfo = profileInfo
        self.domains = domains
        self.primaryDomain = primaryDomain
        self.settingPrimaryDomainId = settingPrimaryDomainId
        self.onSetPrimary = onSetPrimary
        self.onInscribeComplete = onInscribeComplete
        self.onTransferComplete = onTransferComplete
        self.onSetupGuideCompleted = onSetupGuideCompleted
        self.onSave = onSave

        let profile = profileInfo.profile ?? .empty
        _avatarUrl = State(initialValue: profile.avatarUrl ?? "")
        _bannerUrl = State(initialValue: profile.bannerUrl ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _x = State(initialValue: profile.x ?? "")
        _website = State(initialValue: profile.website ?? "")
        _telegram = State(initialValue: profile.telegram ?? "")
        _discord = State(initialValue: profile.discord ?? "")
        _contactEmail = State(initialValue: profile.contactEmail ?? "")
        _github = State(initialValue: profile.github ?? "")
        _redirectUrl = State(initialValue: profile.redirectUrl ?? "")
    }

    private var canSave: Bool {
        !isLoadingAvatar && !isLoadingBanner
    }

    private var displayName: String {
        guard let raw = profileInfo.domainName else { return "KNS Profile" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KNS Profile" : trimmed
    }

    var body: some View {
        NavigationStack {
            Form {
                if walletManager.showSetupGuides {
                    Section {
                        Button {
                            showSetupGuide = true
                        } label: {
                            Text("Setup Guide")
                        }
                    } footer: {
                        // Re-enters the same guided wizard used to create a profile from scratch -
                        // it already knows (via `existingProfile`) to offer skipping domain
                        // registration and pre-fill the banner/avatar/detail steps with whatever's
                        // already inscribed, so this is a safe re-entry point regardless of how much
                        // of a profile already exists. Lives here (rather than next to "KNS Profile"
                        // on the Profile tab) since that spot sits directly beside the banner image,
                        // which made it untappable whenever a banner was set.
                        Text("Walk through setting up your domain, banner, avatar, and details step by step.")
                    }
                }

                Section("Avatar") {
                    HStack(spacing: 12) {
                        if let avatarPreviewImage {
                            Image(uiImage: avatarPreviewImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                        } else {
                            KNSAvatarView(
                                avatarURLString: avatarUrl,
                                fallbackText: displayName,
                                size: 64
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                                Label("Choose Avatar", systemImage: "photo")
                            }
                            if !avatarUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || avatarUploadData != nil {
                                Button(role: .destructive) {
                                    clearAvatarSelection()
                                } label: {
                                    Label("Remove Avatar", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if isLoadingAvatar {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Processing avatar...")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Banner") {
                    Group {
                        if let bannerPreviewImage {
                            Image(uiImage: bannerPreviewImage)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if KNSProfileLinkBuilder.websiteURL(from: bannerUrl) != nil {
                            KNSBannerImageView(
                                bannerURLString: bannerUrl,
                                height: 110,
                                cornerRadius: 10
                            )
                        }
                    }

                    PhotosPicker(selection: $bannerPickerItem, matching: .images) {
                        Label("Choose Banner", systemImage: "photo.on.rectangle")
                    }
                    if !bannerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bannerUploadData != nil {
                        Button(role: .destructive) {
                            clearBannerSelection()
                        } label: {
                            Label("Remove Banner", systemImage: "trash")
                        }
                    }
                    if isLoadingBanner {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Processing banner...")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Profile") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $bio)
                            .frame(minHeight: 84)
                    }
                    TextField("X handle", text: $x)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Website", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Telegram", text: $telegram)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Discord user id", text: $discord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Email", text: $contactEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    TextField("GitHub", text: $github)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Redirect URL", text: $redirectUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let imageLoadError, !imageLoadError.isEmpty {
                    Section {
                        Text(imageLoadError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                Section("Domain") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(displayName)
                            .foregroundColor(.secondary)
                    }
                    if let assetId = profileInfo.assetId, !assetId.isEmpty {
                        HStack {
                            Text("Asset ID")
                            Spacer()
                            Text(assetId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        KNSDomainsListView(
                            walletAddress: profileInfo.address,
                            domains: domains,
                            primaryDomain: primaryDomain,
                            settingPrimaryDomainId: settingPrimaryDomainId,
                            onSetPrimary: onSetPrimary,
                            onInscribeComplete: onInscribeComplete,
                            onTransferComplete: onTransferComplete
                        )
                    } label: {
                        HStack {
                            Text("Domains")
                            Spacer()
                            Text("\(domains.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit KNS Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            KNSProfileEditorSubmission(
                                avatarUrl: avatarUrl,
                                bannerUrl: bannerUrl,
                                bio: bio,
                                x: x,
                                website: website,
                                telegram: telegram,
                                discord: discord,
                                contactEmail: contactEmail,
                                github: github,
                                redirectUrl: redirectUrl,
                                avatarUploadData: avatarUploadData,
                                avatarUploadMimeType: avatarUploadMimeType,
                                bannerUploadData: bannerUploadData,
                                bannerUploadMimeType: bannerUploadMimeType
                            )
                        )
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: avatarPickerItem) { newValue in
                guard let newValue else { return }
                Task {
                    await loadPickedImage(newValue, kind: .avatar)
                }
            }
            .onChange(of: bannerPickerItem) { newValue in
                guard let newValue else { return }
                Task {
                    await loadPickedImage(newValue, kind: .banner)
                }
            }
            .fullScreenCover(isPresented: $showSetupGuide) {
                KNSCreateProfileFlowView(walletAddress: profileInfo.address, existingProfile: profileInfo) {
                    // Dismisses the whole editor (not just the wizard) rather than returning to
                    // it - this sheet's own @State (bio/avatarUrl/etc.) was seeded once when it
                    // opened, so if it stayed open it could show stale values for whatever the
                    // wizard just changed, and tapping this sheet's own Save afterward could
                    // silently overwrite what the wizard just wrote. Refreshing via
                    // onSetupGuideCompleted and closing avoids that entirely.
                    showSetupGuide = false
                    onSetupGuideCompleted()
                    dismiss()
                }
            }
        }
    }

    private enum PickedImageKind {
        case avatar
        case banner
    }

    private func clearAvatarSelection() {
        avatarUrl = ""
        avatarPreviewImage = nil
        avatarUploadData = nil
        avatarUploadMimeType = nil
        avatarPickerItem = nil
        imageLoadError = nil
    }

    private func clearBannerSelection() {
        bannerUrl = ""
        bannerPreviewImage = nil
        bannerUploadData = nil
        bannerUploadMimeType = nil
        bannerPickerItem = nil
        imageLoadError = nil
    }

    private func loadPickedImage(_ item: PhotosPickerItem, kind: PickedImageKind) async {
        await MainActor.run {
            imageLoadError = nil
            switch kind {
            case .avatar:
                isLoadingAvatar = true
            case .banner:
                isLoadingBanner = true
            }
        }

        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                throw KasiaError.apiError(String(localized: "Could not load selected image"))
            }

            let prepared = try prepareImageForUpload(rawData)
            guard !prepared.data.isEmpty else {
                throw KasiaError.apiError(String(localized: "Could not encode selected image"))
            }
            await MainActor.run {
                switch kind {
                case .avatar:
                    avatarPreviewImage = prepared.image
                    avatarUploadData = prepared.data
                    avatarUploadMimeType = prepared.mimeType
                case .banner:
                    bannerPreviewImage = prepared.image
                    bannerUploadData = prepared.data
                    bannerUploadMimeType = prepared.mimeType
                }
            }
        } catch {
            await MainActor.run {
                imageLoadError = error.localizedDescription
                Haptics.impact(.medium)
            }
        }

        await MainActor.run {
            switch kind {
            case .avatar:
                isLoadingAvatar = false
            case .banner:
                isLoadingBanner = false
            }
        }
    }

    private func prepareImageForUpload(_ rawData: Data) throws -> (image: UIImage, data: Data, mimeType: String) {
        let maxDimension: CGFloat = 1400
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
            throw KasiaError.apiError(String(localized: "Selected data is not a valid image"))
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw KasiaError.apiError(String(localized: "Could not process selected image"))
        }

        let previewImage = UIImage(cgImage: cgImage)
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw KasiaError.apiError(String(localized: "Could not initialize image encoder"))
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw KasiaError.apiError(String(localized: "Could not encode selected image"))
        }

        return (previewImage, outputData as Data, "image/png")
    }
}

private struct KNSDomainsListView: View {
    let walletAddress: String
    let domains: [KNSDomain]
    let primaryDomain: String?
    let settingPrimaryDomainId: String?
    let onSetPrimary: (KNSDomain) -> Void
    let onInscribeComplete: (KNSDomainInscribeResult) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void

    @State private var showInscribeSheet = false
    @State private var transferTarget: TransferTarget?

    private struct TransferTarget: Identifiable {
        let id = UUID()
        let domain: KNSDomain
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if domains.isEmpty {
                    Text("No domains yet.")
                        .foregroundColor(.secondary)
                        .padding(16)
                } else {
                    ForEach(Array(domains.enumerated()), id: \.element.inscriptionId) { index, domain in
                        domainRow(domain)
                        if index < domains.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .background(glassBackground(cornerRadius: 18))
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showInscribeSheet = true
            } label: {
                Text("Inscribe New Domain")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(Color.accentColor))
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .navigationTitle("Domains")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInscribeSheet) {
            KNSDomainInscribeSheet(walletAddress: walletAddress) { result in
                showInscribeSheet = false
                onInscribeComplete(result)
            }
        }
        .sheet(item: $transferTarget) { target in
            KNSDomainTransferSheet(walletAddress: walletAddress, domain: target.domain) { result in
                transferTarget = nil
                onTransferComplete(result)
            }
        }
    }

    private func domainRow(_ domain: KNSDomain) -> some View {
        HStack(spacing: 10) {
            Text(domain.fullName)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            if isPrimaryDomain(domain.fullName) {
                Text("Primary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            } else if isSetPrimaryAllowed(domain) {
                Button {
                    onSetPrimary(domain)
                } label: {
                    if settingPrimaryDomainId == domain.inscriptionId {
                        ProgressView()
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "star")
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(settingPrimaryDomainId != nil)
                .accessibilityLabel("Set \(domain.fullName) as primary")
            }

            if isDomainTransferAllowed(domain) {
                Button {
                    transferTarget = TransferTarget(domain: domain)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Transfer \(domain.fullName)")
            } else if domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "listed" {
                Text("Listed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }

    private func isPrimaryDomain(_ domainName: String) -> Bool {
        let normalizedDomain = domainName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrimary = (primaryDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedDomain == normalizedPrimary
    }

    private func isSetPrimaryAllowed(_ domain: KNSDomain) -> Bool {
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && !isPrimaryDomain(domain.fullName)
    }

    private func isDomainTransferAllowed(_ domain: KNSDomain) -> Bool {
        let status = domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && status != "listed"
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

private struct KNSDomainInscribeSheet: View {
    let walletAddress: String
    let onComplete: (KNSDomainInscribeResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var domainInput = ""
    @State private var feeTiers: [Int: Decimal] = [:]
    @State private var availability: KNSDomainAvailability?
    @State private var isCheckingAvailability = false
    @State private var isSubmitting = false
    @State private var feeError: String?
    @State private var checkError: String?
    @State private var submitError: String?
    @State private var checkTask: Task<Void, Never>?

    private var normalizedLabel: String? {
        KNSService.shared.normalizeDomainLabel(domainInput)
    }

    private var fullDomain: String? {
        guard let normalizedLabel else { return nil }
        return "\(normalizedLabel).kas"
    }

    private var currentServiceFeeKas: Decimal? {
        guard let label = normalizedLabel else { return nil }
        guard !feeTiers.isEmpty else { return nil }
        if availability?.isReservedDomain == true {
            return 0
        }
        let tier = min(max(label.count, 1), 5)
        return feeTiers[tier] ?? feeTiers[5]
    }

    private var canSubmit: Bool {
        guard !isSubmitting, !isCheckingAvailability else { return false }
        guard normalizedLabel != nil else { return false }
        guard availability?.available == true else { return false }
        return currentServiceFeeKas != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain") {
                    TextField("name", text: $domainInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let fullDomain {
                        Text(fullDomain)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Use lowercase letters, numbers, and hyphen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if isCheckingAvailability {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Checking availability...")
                                .foregroundColor(.secondary)
                        }
                    } else if let checkError, !checkError.isEmpty {
                        Text(checkError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    } else if let availability {
                        Text(
                            availability.available
                            ? localizedFormat("%@ can be inscribed.", availability.domain)
                            : String(localized: "This domain is not available.")
                        )
                        .font(.footnote)
                        .foregroundColor(availability.available ? .green : .red)
                    }
                }

                Section("Fee") {
                    if let fee = currentServiceFeeKas {
                        HStack {
                            Text("Service fee")
                            Spacer()
                            Text("\(formatKas(fee)) KAS")
                                .foregroundColor(.secondary)
                        }
                        if availability?.isReservedDomain == true {
                            Text("Reserved domain: no revenue payment is required.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Fee unavailable")
                            .foregroundColor(.secondary)
                    }

                    if let feeError, !feeError.isEmpty {
                        Text(feeError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if isSubmitting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Submitting inscription...")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let submitError, !submitError.isEmpty {
                    Section {
                        Text(submitError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Inscribe Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Inscribe") {
                        submitInscribe()
                    }
                    .disabled(!canSubmit)
                }
            }
            .task {
                await loadFeeTiers()
            }
            .onChange(of: domainInput) { _ in
                scheduleAvailabilityCheck()
            }
            .onDisappear {
                checkTask?.cancel()
            }
        }
    }

    private func loadFeeTiers() async {
        do {
            let tiers = try await KNSService.shared.fetchInscribeFeeTiers()
            await MainActor.run {
                feeTiers = tiers
                feeError = nil
            }
        } catch {
            await MainActor.run {
                feeError = error.localizedDescription
            }
        }
    }

    private func scheduleAvailabilityCheck() {
        checkTask?.cancel()
        submitError = nil
        availability = nil

        let raw = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            checkError = nil
            isCheckingAvailability = false
            return
        }
        guard let label = normalizedLabel else {
            checkError = String(localized: "Use lowercase letters, numbers, and hyphen.")
            isCheckingAvailability = false
            return
        }

        checkError = nil
        isCheckingAvailability = true
        let full = "\(label).kas"
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await KNSService.shared.checkDomainAvailability(
                    address: walletAddress,
                    domainName: full
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    availability = result
                    isCheckingAvailability = false
                    checkError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    availability = nil
                    isCheckingAvailability = false
                    checkError = error.localizedDescription
                }
            }
        }
    }

    private func submitInscribe() {
        guard let label = normalizedLabel else {
            submitError = String(localized: "Invalid domain label")
            return
        }
        isSubmitting = true
        submitError = nil
        Task {
            do {
                let result = try await KNSDomainInscribeService.shared.inscribeDomain(label: label)
                await MainActor.run {
                    isSubmitting = false
                    onComplete(result)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                    Haptics.impact(.medium)
                }
            }
        }
    }

    private func formatKas(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let double = number.doubleValue
        if abs(double.rounded() - double) < 0.0000001 {
            return String(format: "%.0f", double)
        }
        return number.stringValue
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }
}

private struct KNSDomainTransferSheet: View {
    let walletAddress: String
    let domain: KNSDomain
    let onComplete: (KNSDomainTransferResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var recipientInput = ""
    @State private var isSubmitting = false
    @State private var submitError: String?

    private var trimmedRecipientInput: String {
        recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRecipientInputPlausible: Bool {
        let value = trimmedRecipientInput
        guard !value.isEmpty else { return false }
        if value.lowercased().hasSuffix(".kas") {
            return true
        }
        return KaspaAddress.isValid(value)
    }

    private var canSubmit: Bool {
        !isSubmitting && isRecipientInputPlausible
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain") {
                    Text(domain.fullName)
                    Text(domain.inscriptionId)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section("Recipient") {
                    TextField("kaspa:... or alice.kas", text: $recipientInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if trimmedRecipientInput.isEmpty {
                        Text("Enter a Kaspa address or a `.kas` domain.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if !isRecipientInputPlausible {
                        Text("Invalid recipient format.")
                            .font(.footnote)
                            .foregroundColor(.red)
                    } else {
                        Text("Recipient looks valid.")
                            .font(.footnote)
                            .foregroundColor(.green)
                    }
                }

                if isSubmitting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Submitting transfer...")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let submitError, !submitError.isEmpty {
                    Section {
                        Text(submitError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Transfer Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Transfer") {
                        submitTransfer()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func submitTransfer() {
        let recipient = trimmedRecipientInput
        guard !recipient.isEmpty else {
            submitError = String(localized: "Recipient is required")
            return
        }
        guard !walletAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            submitError = String(localized: "Wallet not available")
            return
        }

        isSubmitting = true
        submitError = nil

        Task {
            do {
                let result = try await KNSDomainTransferService.shared.transferDomain(
                    domain: domain.fullName,
                    assetId: domain.inscriptionId,
                    to: recipient
                )
                await MainActor.run {
                    isSubmitting = false
                    onComplete(result)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                    Haptics.impact(.medium)
                }
            }
        }
    }
}

/// Transaction history for the chatting (identity) address, reached from its dropdown in
/// Profile. Same pattern as ManageAddressesView's SpendingAddressTransactionHistoryView: tapping
/// a transaction opens it directly on whichever block explorer is selected in Settings >
/// Connection > Kaspa Explorer, rather than showing an in-app detail screen.
private struct ChattingAddressTransactionHistoryView: View {
    let address: String

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var transactions: [KaspaFullTransactionResponse] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading && transactions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(transactions, id: \.transactionId) { tx in
                    Button {
                        openInExplorer(tx)
                    } label: {
                        transactionRow(tx)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chatting Address")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTransactions()
        }
        .refreshable {
            await loadTransactions()
        }
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        let info = tx.direction(for: address)
        return HStack(spacing: 12) {
            Image(systemName: info?.isOutgoing == true ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))

            VStack(alignment: .leading, spacing: 2) {
                Text(info == nil ? "Transaction" : (info!.isOutgoing ? "Sent" : "Received"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))
                Text(tx.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockTime = tx.blockTime {
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let info {
                    Text("\(info.isOutgoing ? "-" : "+")\(formatKasExact(info.amountSompi)) KAS")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(info.isOutgoing ? .red : .green)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func loadTransactions() async {
        isLoading = true
        transactions = await chatService.fetchFullTransactionsPaginated(for: address, pageSize: 50, maxTransactions: 200)
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Dedicated white-background QR display, matching Android's "Accept Kaspa"/"Chatting Address"
/// QR screen — deliberately uses literal black/white colors rather than adaptive .primary/
/// .secondary, since forcing a white content area regardless of system dark/light mode would
/// otherwise leave semantic text colors resolved for dark mode (and invisible on the white
/// background) unless the whole screen's color scheme were overridden too.
struct ChattingAddressQRView: View {
    let address: String
    let balanceSompi: UInt64?
    var subtitle: String = "Just send 5-10 KAS at a time, that's plenty to cover chat fees for a while (about 500 messages per KAS)"

    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        Color.white
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 28) {
                    Spacer()
                    Group {
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 240, height: 240)
                        } else {
                            ProgressView()
                                .frame(width: 240, height: 240)
                        }
                    }
                    .padding(20)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 3)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(address)
                        .font(.footnote.monospaced())
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 40)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(Color.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button {
                        UIPasteboard.general.string = address
                        Haptics.success()
                        showToast("Address copied to clipboard.")
                    } label: {
                        Label("Copy Address", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }

                    Spacer()
                    Spacer()
                }
            )
            .toast(message: toastMessage)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(balanceSompi.map { "\(formatKaspaExact($0)) KAS" } ?? "—")
                        .font(.caption)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                qrImage = ProfileQRCodeCache.cachedImage(for: address)
                ProfileQRCodeCache.preload(address: address) { image in
                    qrImage = image
                }
            }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }
}

/// Fee-priority tiers for the Withdraw Kaspa flow — each tier is a multiplier applied to the
/// already-estimated base (Normal) fee, letting the user pay extra during network congestion
/// without a second network round-trip per tier.
enum WithdrawFeeTier: String, CaseIterable, Identifiable, Hashable {
    case normal = "Normal"
    case fast = "Fast"
    case priority = "Priority"

    var id: String { rawValue }

    var multiplier: UInt64 {
        switch self {
        case .normal: return 1
        case .fast: return 2
        case .priority: return 5
        }
    }
}

/// Custom success card replacing a plain alert so the transaction id can be a real tappable
/// link (native SwiftUI alerts can't embed interactive text in their message) - shared by every
/// "you just sent Kaspa" flow (chatting-address withdraw, Manage Addresses' per-address send).
struct WithdrawalSuccessCard: View {
    let txId: String
    let explorerURL: URL?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)

            Text("Sent")
                .font(.headline)
                .fontWeight(.bold)

            if let explorerURL {
                Link(destination: explorerURL) {
                    Text(txId)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .underline()
                        .multilineTextAlignment(.center)
                }
            } else {
                Text(txId)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onDismiss()
            } label: {
                Text("OK")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

/// Sends a plain KAS transfer from the wallet's chatting (identity) address to an arbitrary
/// recipient address. Reuses AddContactView's address-entry conventions (paste/QR scan,
/// live validation) but with an amount field instead of a contact-name field, since this
/// isn't creating a contact.
private struct WithdrawKaspaView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64?

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var amountInput = ""
    @State private var showQRScanner = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successTxId: String?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var isEstimatingMax = false
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input).
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var amountSompi: UInt64? {
        guard let kas = Double(amountInput), kas > 0 else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    /// True once we have a usable recipient — either a resolved KNS domain or a directly
    /// valid Kaspa address (mirrors AddContactView.canAdd's precedence).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion.
    /// A manually-entered custom fee (tapped on the Network Fee row) overrides the tier
    /// multiplier until a tier is tapped again.
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard let normalFeeSompi else { return nil }
        return normalFeeSompi + extraFeeSompi
    }

    /// Debounce/cancellation key: only re-estimate when the resolved address or amount
    /// actually changes, not on every fee-tier tap (the tier is applied client-side as a
    /// multiplier of the already-fetched base fee, no extra network round-trip needed).
    private var feeEstimationKey: String {
        "\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("kaspa:qr... or name.kas", text: $addressInput)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: addressInput) { handleInputChange($0) }

                    if !addressInput.isEmpty {
                        if isResolvingKNS {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Resolving KNS domain...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if let knsError {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(knsError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        } else if let resolvedAddress {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Resolved: \(resolvedDomain ?? "")")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                Text(resolvedAddress)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            HStack {
                                Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(isValidAddress ? .green : .red)
                                Text(isValidAddress ? "Valid address" : "Invalid address format")
                                    .font(.caption)
                                    .foregroundColor(isValidAddress ? .green : .red)
                            }
                        }
                    }

                    HStack {
                        Button {
                            if let pasted = UIPasteboard.general.string {
                                addressInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                handleInputChange(addressInput)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Button {
                            showQRScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Recipient Address")
                } footer: {
                    Text("Enter a Kaspa address (kaspa:...)")
                }

                Section {
                    HStack {
                        TextField(
                            "0.00",
                            text: Binding(
                                get: { fiatAmountState.displayText },
                                set: { amountInput = fiatAmountState.onDisplayTextChange($0, priceInCurrency: portfolioViewModel.currentPriceUsd) }
                            )
                        )
                            .keyboardType(.decimalPad)
                        if let conversionLabel = fiatAmountState.conversionLabelText(
                            priceInCurrency: portfolioViewModel.currentPriceUsd,
                            currency: portfolioViewModel.currentCurrency
                        ) {
                            Text(conversionLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .onTapGesture {
                                    fiatAmountState.toggleMode(priceInCurrency: portfolioViewModel.currentPriceUsd)
                                }
                        }
                        if isEstimatingMax {
                            ProgressView().scaleEffect(0.75)
                        } else {
                            Button("Max") {
                                setMaxAmount()
                            }
                            .font(.caption)
                            .fontWeight(.semibold)
                            .buttonStyle(.borderless)
                            .disabled(!hasValidRecipient)
                        }
                        Text(fiatAmountState.isFiatMode ? portfolioViewModel.currentCurrency.code : "KAS")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    if let availableBalanceSompi {
                        Text("Available: \(trimmedKas(availableBalanceSompi)) KAS")
                    }
                }

                Section {
                    Picker("Fee", selection: $feeTier) {
                        ForEach(WithdrawFeeTier.allCases) { tier in
                            Text(tier.rawValue).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: feeTier) { _ in
                        customExtraFeeSompi = nil
                        isEditingFee = false
                    }

                    HStack {
                        Text("Network Fee")
                        Spacer()
                        if isEditingFee {
                            TextField("0.00", text: $customFeeText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                .onSubmit { commitCustomFee() }
                            Button {
                                commitCustomFee()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        } else if isEstimatingFee {
                            ProgressView().scaleEffect(0.75)
                        } else if let totalFeeSompi {
                            Button {
                                startEditingFee()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(trimmedKas(totalFeeSompi)) KAS")
                                        .underline()
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("—")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Fee")
                } footer: {
                    Text("If the network is busy, Fast or Priority pays a higher fee to help your withdrawal confirm sooner. Tap the fee amount to set a custom fee.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Withdraw Kaspa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            send()
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .overlay {
                if let successTxId {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture { dismiss() }
                        WithdrawalSuccessCard(
                            txId: successTxId,
                            explorerURL: settingsViewModel.settings.kaspaExplorer.txURL(for: successTxId)
                        ) {
                            dismiss()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: successTxId)
            .task(id: feeEstimationKey) {
                guard hasValidRecipient, let amountSompi else {
                    normalFeeSompi = nil
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let fee = try await chatService.estimateWithdrawalFee(toAddress: effectiveAddress, amountSompi: amountSompi)
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = fee
                } catch {
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = nil
                }
                isEstimatingFee = false
            }
        }
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            isValidAddress = contactsManager.isValidKaspaAddress(trimmed)
            return
        }

        if KNSService.looksLikeDomain(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            if let resolution = await knsService.resolveDomain(domain) {
                await MainActor.run {
                    resolvedAddress = resolution.ownerAddress
                    resolvedDomain = resolution.domain
                    knsError = nil
                    isResolvingKNS = false
                }
            } else {
                await MainActor.run {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    knsError = "KNS domain not found"
                    isResolvingKNS = false
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        addressInput = address
        handleInputChange(address)
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        isEstimatingMax = true
        errorMessage = nil
        let recipient = effectiveAddress
        let tipSompi = extraFeeSompi
        Task {
            do {
                let maxSompi = try await chatService.estimateMaxWithdrawalAmount(toAddress: recipient, extraFeeSompi: tipSompi)
                await MainActor.run {
                    amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isEstimatingMax = false
                }
            }
        }
    }

    private func startEditingFee() {
        guard let totalFeeSompi else { return }
        customFeeText = trimmedKas(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright — a transaction can't
    /// actually be submitted under the minimum, so silently flooring it is friendlier than
    /// an error for a value the user almost certainly meant as "as low as possible."
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let normalFeeSompi, let kas = Double(customFeeText), kas >= 0 else { return }
        let totalSompi = UInt64((kas * 100_000_000).rounded())
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func send() {
        guard let amountSompi else { return }
        isSending = true
        errorMessage = nil
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        Task {
            do {
                let txId = try await chatService.sendWithdrawal(toAddress: recipient, amountSompi: amountSompi, extraFeeSompi: tipSompi)
                await MainActor.run {
                    isSending = false
                    successTxId = txId
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func trimmedKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

private enum ProfileQRCodeCache {
    static let context = CIContext()
    static let imageCache = NSCache<NSString, UIImage>()
    static let renderQueue = DispatchQueue(label: "kasia.profile.qr.render", qos: .utility)

    static func cachedImage(for address: String) -> UIImage? {
        let uri = receiveURI(for: address)
        let key = uri as NSString
        return imageCache.object(forKey: key)
    }

    static func preload(address: String, completion: ((UIImage?) -> Void)?) {
        let uri = receiveURI(for: address)
        let key = uri as NSString

        if let cached = imageCache.object(forKey: key) {
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        renderQueue.async {
            let image = generateImage(uri: uri)
            if let image {
                imageCache.setObject(image, forKey: key)
            }
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func generateImage(uri: String) -> UIImage? {
        let data = Data(uri.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func receiveURI(for address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("kaspa:") {
            return trimmed
        }
        return "kaspa:\(trimmed)"
    }
}

enum SystemContactImportSelection: Identifiable, Equatable {
    case withAddress(SystemContactCandidate)
    case nameOnly(SystemContactLinkTarget)

    var id: String {
        switch self {
        case .withAddress(let candidate):
            return "address:\(candidate.id)"
        case .nameOnly(let target):
            return "nameOnly:\(target.id)"
        }
    }

    var displayName: String {
        switch self {
        case .withAddress(let candidate):
            return candidate.displayName
        case .nameOnly(let target):
            return target.displayName
        }
    }

    var address: String? {
        switch self {
        case .withAddress(let candidate):
            return candidate.address
        case .nameOnly:
            return nil
        }
    }
}

struct SystemContactPickerSheet: View {
    let title: String
    let onSelect: (SystemContactImportSelection) -> Void

    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.dismiss) private var dismiss
    @State private var selections: [SystemContactImportSelection] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            Group {
                if permissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Contacts access is required.")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading contacts...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if filteredSelections.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No contacts found.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(filteredSelections) { selection in
                        Button {
                            onSelect(selection)
                            dismiss()
                        } label: {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selection.displayName)
                                        .foregroundColor(.primary)
                                    if let address = selection.address {
                                        Text(address)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("No Kaspa address in system contact")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadCandidates()
            }
        }
    }

    private var filteredSelections: [SystemContactImportSelection] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return selections }
        return selections.filter { selection in
            if selection.displayName.lowercased().contains(q) {
                return true
            }
            if let address = selection.address, address.lowercased().contains(q) {
                return true
            }
            return false
        }
    }

    private func loadCandidates() async {
        isLoading = true
        let candidates = await contactsManager.loadSystemContactCandidates(promptIfNeeded: true)
        permissionDenied = !contactsManager.systemContactsAuthorized
        guard !permissionDenied else {
            selections = []
            isLoading = false
            return
        }

        let linkTargets = await contactsManager.loadSystemContactLinkTargets(promptIfNeeded: false)
        let identifiersWithAddress = Set(candidates.map(\.contactIdentifier))
        let nameOnlyTargets = linkTargets.filter { !identifiersWithAddress.contains($0.contactIdentifier) }

        var mergedSelections = candidates.map { SystemContactImportSelection.withAddress($0) }
        mergedSelections += nameOnlyTargets.map { SystemContactImportSelection.nameOnly($0) }
        mergedSelections.sort { lhs, rhs in
            if lhs.displayName == rhs.displayName {
                return (lhs.address ?? "") < (rhs.address ?? "")
            }
            return lhs.displayName < rhs.displayName
        }

        selections = mergedSelections
        isLoading = false
    }
}

struct SystemContactLinkPickerSheet: View {
    let title: String
    let onSelect: (SystemContactLinkTarget) -> Void

    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [SystemContactLinkTarget] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            Group {
                if permissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Contacts access is required.")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading contacts...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if filteredTargets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No system contacts found.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(filteredTargets) { target in
                        Button {
                            onSelect(target)
                            dismiss()
                        } label: {
                            HStack(spacing: 0) {
                                Text(target.displayName)
                                    .foregroundColor(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadTargets()
            }
        }
    }

    private var filteredTargets: [SystemContactLinkTarget] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return targets }
        return targets.filter { $0.displayName.lowercased().contains(q) }
    }

    private func loadTargets() async {
        isLoading = true
        targets = await contactsManager.loadSystemContactLinkTargets(promptIfNeeded: true)
        permissionDenied = !contactsManager.systemContactsAuthorized
        isLoading = false
    }
}

#Preview {
    ProfileView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(GiftService.shared)
}
