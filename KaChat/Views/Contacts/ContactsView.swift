import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import PhotosUI

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
        if isLoadingKNS {
            Section("KNS Domains") {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading domains...")
                        .foregroundColor(.secondary)
                }
            }
        } else if !knsDomains.isEmpty {
            Section("KNS Domains") {
                ForEach(knsDomains, id: \.inscriptionId) { domain in
                    Button {
                        applyDomainAsAccountName(domain.fullName)
                    } label: {
                        HStack {
                            Text(domain.fullName)
                                .font(.body)
                                .foregroundColor(.primary)
                            if domain.fullName == knsPrimaryDomain {
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
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func applyDomainAsAccountName(_ domain: String) {
        editedAlias = domain
        Haptics.success()
        Task {
            try? await walletManager.updateAlias(domain)
            showToast("Name set to \(domain).")
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
                                    Text("Retry \(key.displayName)")
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

                if let bannerURL = KNSProfileLinkBuilder.websiteURL(from: profileInfo.profile?.bannerUrl) {
                    AsyncImage(url: bannerURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .empty:
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 120)
                                .overlay {
                                    ProgressView().scaleEffect(0.8)
                                }
                        case .failure:
                            EmptyView()
                        @unknown default:
                            EmptyView()
                        }
                    }
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

    private func formatDate(_ date: Date) -> String {
        SharedFormatting.mediumDateShortTime.string(from: date)
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

    @ViewBuilder
    private func profileLinkView(text: String, url: URL?, fieldName: String) -> some View {
        Group {
            if let url {
                Link(text, destination: url)
            } else {
                Text(text).foregroundColor(.secondary)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            copyProfileFieldValue(text, fieldName: fieldName)
        }
    }

    private func copyProfileFieldValue(_ value: String, fieldName: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        showToast("\(fieldName) copied to clipboard.")
    }

    private func saveKNSProfile(
        submission: KNSProfileEditorSubmission,
        profileInfo: KNSAddressProfileInfo
    ) async {
        guard let walletAddress = walletManager.currentWallet?.publicAddress else {
            await MainActor.run {
                showToast("Wallet not available.", style: .error)
            }
            return
        }
        guard let assetId = profileInfo.assetId, !assetId.isEmpty else {
            await MainActor.run {
                showToast("KNS asset id is missing.", style: .error)
            }
            return
        }

        await MainActor.run {
            isSavingKNSProfile = true
            knsSaveProgressText = "Preparing profile update..."
            failedKNSUpdates = [:]
        }

        var values = submission.fieldValues()

        do {
            // Upload picked avatar/banner first; resulting URLs are written on-chain.
            if let avatarData = submission.avatarUploadData {
                await MainActor.run {
                    knsSaveProgressText = "Uploading avatar..."
                }
                let signMessage = try KNSService.shared.buildImageUploadSigningMessage(
                    assetId: assetId,
                    uploadType: .avatar
                )
                let signature = try walletManager.signArbitraryMessage(signMessage)
                let uploadedURL = try await KNSService.shared.uploadProfileImage(
                    assetId: assetId,
                    uploadType: .avatar,
                    imageData: avatarData,
                    mimeType: submission.avatarUploadMimeType ?? "image/jpeg",
                    signMessage: signMessage,
                    signature: signature
                )
                values[.avatarUrl] = uploadedURL
            }

            if let bannerData = submission.bannerUploadData {
                await MainActor.run {
                    knsSaveProgressText = "Uploading banner..."
                }
                let signMessage = try KNSService.shared.buildImageUploadSigningMessage(
                    assetId: assetId,
                    uploadType: .banner
                )
                let signature = try walletManager.signArbitraryMessage(signMessage)
                let uploadedURL = try await KNSService.shared.uploadProfileImage(
                    assetId: assetId,
                    uploadType: .banner,
                    imageData: bannerData,
                    mimeType: submission.bannerUploadMimeType ?? "image/jpeg",
                    signMessage: signMessage,
                    signature: signature
                )
                values[.bannerUrl] = uploadedURL
            }

            if let email = values[.contactEmail],
               !email.isEmpty,
               !isLikelyValidEmail(email) {
                throw KasiaError.apiError("Invalid email address format")
            }
            if let discord = values[.discord],
               !discord.isEmpty,
               KNSProfileLinkBuilder.discordURL(from: discord) == nil {
                throw KasiaError.apiError("Discord must be a numeric user id or a valid /users/<id> URL")
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
                await MainActor.run {
                    isSavingKNSProfile = false
                    knsSaveProgressText = nil
                    showToast("No KNS profile changes detected.")
                }
                return
            }

            var successCount = 0
            var failedFields: [String] = []
            var failedChanges: [KNSProfileFieldKey: String] = [:]

            for change in changes {
                try validateKNSFieldValue(change.value, key: change.key, assetId: assetId)
            }

            for (index, change) in changes.enumerated() {
                await MainActor.run {
                    knsSaveProgressText = "Updating \(change.key.displayName) (\(index + 1)/\(changes.count))..."
                }
                do {
                    _ = try await KNSProfileWriteService.shared.submitAddProfile(
                        assetId: assetId,
                        key: change.key,
                        value: change.value,
                        domainName: profileInfo.domainName
                    )
                    successCount += 1
                } catch {
                    failedFields.append(change.key.displayName)
                    failedChanges[change.key] = change.value
                    NSLog("[KNS] Failed to update %@: %@", change.key.rawValue, error.localizedDescription)
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
                    Haptics.success()
                    showToast("KNS profile updated.")
                } else if successCount > 0 {
                    Haptics.impact(.medium)
                    let failedList = failedFields.joined(separator: ", ")
                    showToast("Updated \(successCount)/\(changes.count). Failed: \(failedList).", style: .error)
                } else {
                    Haptics.impact(.medium)
                    showToast("KNS profile update failed.", style: .error)
                }
            }
        } catch {
            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                Haptics.impact(.medium)
                showToast(error.localizedDescription, style: .error)
            }
        }
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
            try validateKNSFieldValue(value, key: key, assetId: assetId)
            await MainActor.run {
                isSavingKNSProfile = true
                knsSaveProgressText = "Retrying \(key.displayName)..."
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
                showToast("\(key.displayName) updated.")
            }
        } catch {
            await MainActor.run {
                isSavingKNSProfile = false
                knsSaveProgressText = nil
                Haptics.impact(.medium)
                showToast("Retry failed: \(error.localizedDescription)", style: .error)
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
                        } else if let bannerURL = KNSProfileLinkBuilder.websiteURL(from: bannerUrl) {
                            AsyncImage(url: bannerURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                case .empty:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(height: 110)
                                        .overlay {
                                            ProgressView().scaleEffect(0.8)
                                        }
                                case .failure:
                                    EmptyView()
                                @unknown default:
                                    EmptyView()
                                }
                            }
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
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: rawData) else {
                throw KasiaError.apiError("Could not load selected image")
            }

            let prepared = prepareImageForUpload(image)
            guard !prepared.data.isEmpty else {
                throw KasiaError.apiError("Could not encode selected image")
            }
            await MainActor.run {
                switch kind {
                case .avatar:
                    avatarPreviewImage = prepared.image
                    avatarUploadData = prepared.data
                    avatarUploadMimeType = "image/jpeg"
                case .banner:
                    bannerPreviewImage = prepared.image
                    bannerUploadData = prepared.data
                    bannerUploadMimeType = "image/jpeg"
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

    private func prepareImageForUpload(_ image: UIImage) -> (image: UIImage, data: Data) {
        let maxDimension: CGFloat = 1400
        let size = image.size
        let largest = max(size.width, size.height)
        let scale = largest > maxDimension ? (maxDimension / largest) : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.opaque = false
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        let encoded = rendered.jpegData(compressionQuality: 0.88) ?? image.jpegData(compressionQuality: 0.88) ?? Data()
        return (rendered, encoded)
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
