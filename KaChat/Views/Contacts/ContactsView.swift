import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

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
