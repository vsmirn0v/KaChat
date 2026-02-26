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

    @State private var editedAlias = ""
    @State private var aliasSaveTask: Task<Void, Never>?
    @State private var showSeedPhrase = false
    @State private var showAddContact = false
    @State private var showLogoutConfirmation = false
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var giftAlreadyClaimedTapCount = 0
    @State private var isLoadingKNS = false
    @State private var knsDomains: [KNSDomain] = []
    @State private var knsPrimaryDomain: String?
    @State private var knsProfileInfo: KNSAddressProfileInfo?
    @State private var showAvatarPreview = false
    @State private var showKNSEditor = false
    @State private var showKNSDomainInscribeSheet = false
    @State private var showKNSDomainTransferSheet = false
    @State private var transferDomainTarget: KNSDomain?
    @State private var settingPrimaryDomainId: String?
    @State private var isSavingKNSProfile = false
    @State private var knsSaveProgressText: String?
    @State private var failedKNSUpdates: [KNSProfileFieldKey: String] = [:]

    static func preloadQRCode(for address: String) {
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

    var body: some View {
        NavigationStack {
            List {
                if let wallet = walletManager.currentWallet {
                    accountNameSection(wallet)
                    knsDomainSection
                    knsProfileSection
                    accountAddressSection(wallet)
                    accountBalanceSection(wallet)
                    if shouldShowGiftSection(wallet) {
                        giftSection
                    }
                    accountInfoSection(wallet)
                    accountActionsSection
                } else {
                    Section("Account") {
                        Text("No active account")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddContact = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(isPresented: $showSeedPhrase) {
                SeedPhraseView()
            }
            .sheet(isPresented: $showAddContact) {
                AddContactView { contact in
                    _ = chatService.getOrCreateConversation(for: contact)
                    showAddContact = false
                    // Navigate to the new chat via the Chats tab
                    NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": contact.address])
                }
            }
            .sheet(isPresented: $showKNSEditor) {
                if let profileInfo = knsProfileInfo, profileInfo.assetId != nil {
                    KNSProfileEditorSheet(profileInfo: profileInfo) { submission in
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
            .sheet(isPresented: $showKNSDomainInscribeSheet) {
                if let walletAddress = walletManager.currentWallet?.publicAddress {
                    KNSDomainInscribeSheet(walletAddress: walletAddress) { result in
                        Haptics.success()
                        showToast(localizedFormat("Inscribe submitted for %@.", result.domain))
                        Task {
                            await refreshKNSData(for: walletAddress)
                        }
                    }
                } else {
                    NavigationStack {
                        VStack(spacing: 12) {
                            Text("Wallet not available.")
                                .foregroundColor(.secondary)
                            Button("Close") {
                                showKNSDomainInscribeSheet = false
                            }
                        }
                        .padding()
                    }
                }
            }
            .sheet(isPresented: $showKNSDomainTransferSheet, onDismiss: {
                transferDomainTarget = nil
            }) {
                if let walletAddress = walletManager.currentWallet?.publicAddress,
                   let domain = transferDomainTarget {
                    KNSDomainTransferSheet(
                        walletAddress: walletAddress,
                        domain: domain
                    ) { result in
                        Haptics.success()
                        let message = result.verified
                            ? localizedFormat("%@ transferred to %@.", result.domain, result.recipientAddress)
                            : localizedFormat("Transfer submitted for %@.", result.domain)
                        showToast(message)
                        Task {
                            await refreshKNSData(for: walletAddress)
                        }
                    }
                } else {
                    NavigationStack {
                        VStack(spacing: 12) {
                            Text("Domain transfer unavailable.")
                                .foregroundColor(.secondary)
                            Button("Close") {
                                showKNSDomainTransferSheet = false
                            }
                        }
                        .padding()
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
            .onAppear {
                if let wallet = walletManager.currentWallet {
                    editedAlias = wallet.alias
                    qrImage = ProfileQRCodeCache.cachedImage(for: wallet.publicAddress)
                    ProfileQRCodeCache.preload(address: wallet.publicAddress) { image in
                        self.qrImage = image
                    }
                }
                Task { _ = try? await walletManager.refreshBalance() }
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

    private func accountNameSection(_ wallet: Wallet) -> some View {
        Section("Name") {
                TextField("Account name", text: $editedAlias)
                .onChange(of: editedAlias) { newValue in
                    scheduleAliasSave(newValue, previousAlias: wallet.alias)
                }
        }
    }

    @ViewBuilder
    private var knsDomainSection: some View {
        Section("KNS Domains") {
            if isLoadingKNS {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading domains...")
                        .foregroundColor(.secondary)
                }
            }
            if !isLoadingKNS && knsDomains.isEmpty {
                Text("No domains yet.")
                    .foregroundColor(.secondary)
            }
            if !knsDomains.isEmpty {
                ForEach(knsDomains, id: \.inscriptionId) { domain in
                    HStack(spacing: 10) {
                        Button {
                            applyDomainAsAccountName(domain.fullName)
                        } label: {
                            HStack {
                                Text(domain.fullName)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                if isPrimaryDomain(domain.fullName) {
                                    Spacer()
                                    Text("Primary")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        if isSetPrimaryAllowed(domain) {
                            Button {
                                Task {
                                    await setPrimaryDomain(domain)
                                }
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
                            .accessibilityLabel(localizedFormat("Set %@ as primary", domain.fullName))
                        }

                        if isDomainTransferAllowed(domain) {
                            Button {
                                startDomainTransfer(domain)
                            } label: {
                                Image(systemName: "arrowshape.turn.up.right")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(localizedFormat("Transfer %@", domain.fullName))
                        } else if domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "listed" {
                            Text("Listed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Button {
                showKNSDomainInscribeSheet = true
            } label: {
                Label("Inscribe New Domain", systemImage: "plus.circle")
            }
        }
    }

    private func applyDomainAsAccountName(_ domain: String) {
        editedAlias = domain
        Haptics.success()
        Task {
            try? await walletManager.updateAlias(domain)
            showToast(localizedFormat("Name set to %@.", domain))
        }
    }

    private func isPrimaryDomain(_ domainName: String) -> Bool {
        let normalizedDomain = domainName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrimary = (knsPrimaryDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func startDomainTransfer(_ domain: KNSDomain) {
        transferDomainTarget = domain
        showKNSDomainTransferSheet = true
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
        if isLoadingKNS && knsProfileInfo == nil {
            Section("KNS Profile") {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading profile...")
                        .foregroundColor(.secondary)
                }
            }
        } else if let profileInfo = knsProfileInfo {
            Section("KNS Profile") {
                HStack(spacing: 12) {
                    Button {
                        showAvatarPreview = true
                    } label: {
                        KNSAvatarView(
                            avatarURLString: profileInfo.avatarURL,
                            fallbackText: editedAlias,
                            size: 64
                        )
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        if let domainName = profileInfo.domainName, !domainName.isEmpty {
                            Text(domainName)
                                .font(.headline)
                        }
                        Text(profileInfo.profile?.hasAnyField == true
                             ? "On-chain profile data available."
                             : "No on-chain profile fields set.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if let assetId = profileInfo.assetId, !assetId.isEmpty {
                    Button {
                        showKNSEditor = true
                    } label: {
                        Label("Edit KNS Profile", systemImage: "pencil")
                    }
                }

                if isSavingKNSProfile, let progress = knsSaveProgressText {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text(progress)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
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
                    .padding(.vertical, 2)
                }

                if KNSProfileLinkBuilder.websiteURL(from: profileInfo.profile?.bannerUrl) != nil {
                    KNSBannerImageView(
                        bannerURLString: profileInfo.profile?.bannerUrl,
                        height: 120,
                        cornerRadius: 10
                    )
                }

                if let bio = profileInfo.profile?.bio {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(bio)
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                    .onLongPressGesture(minimumDuration: 0.45) {
                        copyProfileFieldValue(bio, fieldName: "Bio")
                    }
                }
                if let x = profileInfo.profile?.x {
                    LabeledContent("X") {
                        profileLinkView(
                            text: x,
                            url: KNSProfileLinkBuilder.xURL(from: x),
                            fieldName: "X"
                        )
                    }
                }
                if let website = profileInfo.profile?.website {
                    LabeledContent("Website") {
                        profileLinkView(
                            text: website,
                            url: KNSProfileLinkBuilder.websiteURL(from: website),
                            fieldName: "Website"
                        )
                    }
                }
                if let telegram = profileInfo.profile?.telegram {
                    LabeledContent("Telegram") {
                        profileLinkView(
                            text: telegram,
                            url: KNSProfileLinkBuilder.telegramURL(from: telegram),
                            fieldName: "Telegram"
                        )
                    }
                }
                if let discord = profileInfo.profile?.discord {
                    LabeledContent("Discord") {
                        profileLinkView(
                            text: discord,
                            url: KNSProfileLinkBuilder.discordURL(from: discord),
                            fieldName: "Discord"
                        )
                    }
                }
                if let contactEmail = profileInfo.profile?.contactEmail {
                    LabeledContent("Email") {
                        profileLinkView(
                            text: contactEmail,
                            url: KNSProfileLinkBuilder.emailURL(from: contactEmail),
                            fieldName: "Email"
                        )
                    }
                }
                if let github = profileInfo.profile?.github {
                    LabeledContent("GitHub") {
                        profileLinkView(
                            text: github,
                            url: KNSProfileLinkBuilder.githubURL(from: github),
                            fieldName: "GitHub"
                        )
                    }
                }
                if let redirectUrl = profileInfo.profile?.redirectUrl {
                    LabeledContent("Redirect") {
                        profileLinkView(
                            text: redirectUrl,
                            url: KNSProfileLinkBuilder.websiteURL(from: redirectUrl),
                            fieldName: "Redirect"
                        )
                    }
                }
            }
        }
    }

    private func shouldShowGiftSection(_ wallet: Wallet) -> Bool {
        wallet.balanceSompi == 0
    }

    @ViewBuilder
    private var giftSection: some View {
        switch giftService.claimState {
        case .checking:
            Section("Gift") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking gift eligibility...")
                        .foregroundColor(.secondary)
                }
            }
        case .eligible:
            Section("Gift") {
                Button {
                    guard let address = walletManager.currentWallet?.publicAddress else { return }
                    Task { await giftService.claimGift(walletAddress: address) }
                } label: {
                    Label("Claim Gift", systemImage: "gift.fill")
                }
            }
        case .claiming:
            Section("Gift") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Claiming gift...")
                        .foregroundColor(.secondary)
                }
            }
        case .claimed:
            Section("Gift") {
                Label("Gift claimed", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        case .alreadyClaimed:
            Section("Gift") {
                Label("Gift already claimed", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        giftAlreadyClaimedTapCount += 1
                        guard giftAlreadyClaimedTapCount >= 10 else { return }
                        giftAlreadyClaimedTapCount = 0
                        giftService.resetClaimStateForRetry()
                        Haptics.success()
                        showToast("Gift claim reset. You can request it again.")
                    }
            }
        case .unavailable:
            EmptyView()
        }
    }

    private var accountActionsSection: some View {
        Section("Actions") {
            Button {
                showSeedPhrase = true
            } label: {
                Label("View Seed Phrase", systemImage: "key")
            }

            Button(role: .destructive) {
                showLogoutConfirmation = true
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
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

    private func accountInfoSection(_ wallet: Wallet) -> some View {
        Section("Info") {
            HStack {
                Text("Created")
                Spacer()
                Text(formatDate(wallet.createdAt))
                    .foregroundColor(.secondary)
            }
        }
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
        NSLocalizedString(key, comment: "")
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
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
        NSLog("[KNS_WRITE_UI] %@", message)
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

    @Environment(\.dismiss) private var dismiss

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
        onSave: @escaping (KNSProfileEditorSubmission) -> Void
    ) {
        self.profileInfo = profileInfo
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
        String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
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
