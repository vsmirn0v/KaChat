import SwiftUI
import WebKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject var walletManager: WalletManager
    // Deliberately NOT observing ChatService here: this screen only *calls* it in an action (via
    // ChatService.shared), it never reads its @Published state in the body. Observing it made the
    // whole Profile scroll recompute on ChatService's high-frequency sync churn (per-message
    // `conversations` mutations, per-RPC node-latency updates) for the first ~15s after login,
    // which was the scroll jank. The connection dot is its own small view with its own observation.
    // Same reasoning for ContactsManager: it is only called into here, via
    // ContactsManager.shared, so observing it made every contact mutation (KNS sweeps, system
    // contact imports, alias edits) rebuild this whole scroll for nothing.
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var editedAlias = ""
    @State private var aliasSaveTask: Task<Void, Never>?
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var isLoadingKNS = false
    @State private var knsDomains: [KNSDomain] = []
    /// The .kas domain whose full profile is being customized (Your Domains > the domain).
    @State private var domainProfileEdit: DomainProfileEditTarget?
    /// Names on the other services (.k, .kaspa), for the Your Domains count.
    @ObservedObject private var nameServices = NameServicesClient.shared
    @State private var knsPrimaryDomain: String?
    @State private var knsProfileInfo: KNSAddressProfileInfo?
    /// Testnet: your `.kachat` label (KACHAT_NAMES.md section 7 - your primary name while you own
    /// it and it is active, else your oldest active name), shown as your name on the hero.
    @State private var kachatLabel: String?
    /// The address profile's sources (a social link each for avatar, banner and bio, looked up
    /// on this device) and Linktree link - testnet.
    @State private var kachatAvatarSource: String?
    @State private var kachatBannerSource: String?
    @State private var kachatBioSource: String?
    @State private var kachatLinktree: String?
    /// The account's .kachat names for the Your Domains count - the same set its .kachat tab
    /// lists (in grace and lapsed included). 0 where the registry isn't launched.
    @State private var kachatOwnedCount = 0
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    @ObservedObject private var socialImages = KachatSocialImageResolver.shared
    @State private var showMoreProfileInfo = false
    @State private var showWithdrawSheet = false
    @State private var spendingAddressBalanceSompi: UInt64?
    @State private var isLoadingSpendingBalance = false
    /// Every revealed spending address together, not just the primary. The row above shows what
    /// the address you are about to spend FROM holds, which is not the same question as how much
    /// this account has - and after a few payments those two numbers diverge a long way.
    @State private var spendingTotalSompi: UInt64?
    /// The pending coalesced refresh - see `scheduleBalanceRefresh`.
    @State private var balanceRefreshTask: Task<Void, Never>?
    @State private var showSpendingAddressWithdraw = false
    @State private var showAvatarPreview = false
    @State private var showKNSEditor = false
    @State private var showCreateKNSProfileFlow = false
    @State private var showKachatSetupGuide = false
    @State private var settingPrimaryDomainId: String?
    /// Result of the last "Set as Primary" tap, shown by the editor sheet itself.
    @State private var setPrimaryMessage: KNSSetPrimaryMessage?
    @State private var isSavingKNSProfile = false
    @State private var knsSaveProgressText: String?
    @State private var failedKNSUpdates: [KNSProfileFieldKey: String] = [:]
    @State private var showSettings = false
    @State private var showNotifCenter = false
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    /// Donate: the Send screen, addressed to KaChat's .kachat name
    @State private var showDonateSheet = false
    private static let donateName = "kachat.kachat"
    @State private var showOpenSourceLicenses = false
    @State private var showLogoutConfirmation = false
    @State private var showWelcomeGuideReplay = false
    @State private var isEditingAccountName = false
    /// .kachat names of this wallet in their grace period: the banner at the top
    @StateObject private var expiredKachatNames = KachatExpiredNamesModel()

    static func preloadQRCode(for address: String) {
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let wallet = walletManager.currentWallet {
                        // one of your .kachat names expired and is in grace: renew it in time
                        if !expiredKachatNames.visible.isEmpty {
                            KachatExpiredNamesBanner(model: expiredKachatNames)
                        }
                        accountNameRow(wallet)
                        profileHeroSection(wallet)
                            .task(id: "\(wallet.publicAddress)-\(kachatRegistry.revision)") {
                                await loadKachatLabel(wallet.publicAddress)
                            }
                        qrButtonsSection(wallet)
                        addressDropdownsSection(wallet)
                        yourDomainsSection
                        settingsSection
                        helpSection
                        logOutSection
                        aboutSection(wallet)
                    } else {
                        Text("No active account")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .task(id: "\(walletManager.currentWallet?.publicAddress ?? "")-\(kachatRegistry.revision)") {
                await expiredKachatNames.load()
            }
            .refreshable {
                _ = try? await walletManager.refreshBalance(force: true)
                await loadSpendingAddressBalance()
            }
            // Pinned large-title header: the system .large title scrolls away with the content,
            // so the title lives here as fixed chrome instead - same font/weight/leading inset
            // as the system large title, with the content sliding underneath through the
            // material (same pinned pattern as PublicChatChannelView's top notice). The nav bar
            // itself runs .inline, where the principal balance view already occupies the title
            // slot - identical to what the bar showed mid-scroll before.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Profile")
                        .font(.largeTitle.weight(.bold))
                    profileShareButton
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 8)
                // Solid screen background, matching the Chats title band: all black in dark
                // mode, no gray material blur.
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // One item per side (dot left, bell right) so the bar's glass pills hug their
                // real content and the principal balance centers naturally. Settings lives next
                // to the pinned "Profile" title below, not in this bar - an earlier
                // hidden-mirror centering trick made iOS 26's Liquid Glass stretch the leading
                // pill into a long empty capsule around the lone dot.
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Global notification center: KaPosts activity, group @mentions, live
                    // public chats. A plain red DOT (no count) signals unread.
                    Button {
                        showNotifCenter = true
                    } label: {
                        // The dot is drawn INSIDE the padded bounds rather than offset out
                        // past the glyph's corner. A toolbar item clips to its own frame, so an
                        // outward offset put most of the dot outside it and the badge came out
                        // as a sliver.
                        Image(systemName: "bell")
                            .padding(4)
                            .overlay(alignment: .topTrailing) {
                                if notifCenter.unreadCount > 0 {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                }
                            }
                    }
                    .accessibilityLabel(Text("Notifications"))
                }
            }
            .sheet(isPresented: $showNotifCenter) {
                GlobalNotificationListView()
            }
            .toast(message: toastMessage, style: toastStyle)
            // KNS save progress: a PERSISTENT banner (state-driven, no auto-dismiss timer) that
            // stays up from "Preparing profile update..." through each "Updating X (n/m)..."
            // step until the save finishes. If fields failed, it flips into a red banner with
            // Retry All / dismiss.
            .overlay(alignment: .bottom) {
                if isSavingKNSProfile {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text(knsSaveProgressText ?? localized("Saving profile..."))
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(.regularMaterial)
                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !failedKNSUpdates.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(localizedFormat("%d profile update(s) failed", failedKNSUpdates.count))
                            .font(.footnote.weight(.semibold))
                        Button {
                            retryAllFailedKNSUpdates()
                        } label: {
                            Text("Retry")
                                .font(.footnote.weight(.bold))
                                .foregroundColor(.accentColor)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        Button {
                            withAnimation(.easeIn(duration: 0.2)) { failedKNSUpdates = [:] }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(.regularMaterial)
                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSavingKNSProfile)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // Posted by the KaPosts profile's Edit KNS Profile button, which routes here rather
            // than rebuilding an editor this screen's state already drives.
            .onReceive(NotificationCenter.default.publisher(for: .openKNSProfileEditor)) { _ in
                showKNSEditor = true
            }
            // "Edit KaChat Profile": the address profile editor, on both networks (see
            // `KaChatProfileEditorSheet`).
            .sheet(isPresented: $showKNSEditor) {
                KaChatProfileEditorSheet()
            }
            // A .kas domain's full profile, customized from Your Domains > the domain.
            .sheet(item: $domainProfileEdit) { target in
                KNSProfileEditorSheet(
                    profileInfo: target.info,
                    domains: $knsDomains,
                    primaryDomain: $knsPrimaryDomain,
                    settingPrimaryDomainId: $settingPrimaryDomainId,
                    setPrimaryMessage: $setPrimaryMessage,
                    onSetPrimary: { domain in
                        Task {
                            await setPrimaryDomain(domain)
                        }
                    },
                    onInscribeComplete: { result in
                        Haptics.success()
                        showToast(localizedFormat("Inscribe submitted for %@.", result.domain))
                        Task {
                            await refreshKNSData(for: target.info.address)
                        }
                    },
                    onTransferComplete: { result in
                        Haptics.success()
                        let message = result.verified
                            ? localizedFormat("%@ transferred to %@.", result.domain, result.recipientAddress)
                            : localizedFormat("Transfer submitted for %@.", result.domain)
                        showToast(message)
                        Task {
                            await refreshKNSData(for: target.info.address)
                        }
                    },
                    onRefreshDomains: {
                        await refreshKNSDomainsOnly(for: target.info.address)
                    }
                ) { submission in
                    domainProfileEdit = nil
                    Task {
                        await saveKNSProfile(submission: submission, profileInfo: target.info)
                    }
                }
            }
            .sheet(isPresented: $showWithdrawSheet) {
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi)
                }
            }
            // Donate goes straight to Send with KaChat's name filled in: it resolves like any
            // typed name (.kachat first, the others under Other domains), no chat opened
            .sheet(isPresented: $showDonateSheet) {
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi,
                                      prefillAddress: Self.donateName)
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
            .fullScreenCover(isPresented: $showKachatSetupGuide) {
                KachatSetupGuideView { showKachatSetupGuide = false }
            }
            .fullScreenCover(isPresented: $showWelcomeGuideReplay) {
                WelcomeGuideView(onFinished: { showWelcomeGuideReplay = false })
            }
            .fullScreenCover(isPresented: $showCreateKNSProfileFlow) {
                if let wallet = walletManager.currentWallet {
                    KNSCreateProfileFlowView(walletAddress: wallet.publicAddress, existingProfile: knsProfileInfo) { wroteSomething in
                        showCreateKNSProfileFlow = false
                        guard wroteSomething else { return }
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
                // Resolve the Receive QR's address NOW, not when the button is tapped. The
                // freshness check is a network round trip, so doing it on tap meant a spinner
                // between pressing Receive Kaspa and seeing a code. Warmed here it is almost
                // always already decided by the time anyone taps.
                Task { await warmReceiveAddress() }
            }
            // Funds landing used to show up here only on the next appear or pull-to-refresh -
            // the screen that shows your balance was the one screen not listening for it.
            // ManageAddresses and Cold Storage already reload on these.
            .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
                scheduleBalanceRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
                scheduleBalanceRefresh()
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
                // Cache-first: these only reach the network when the entries read above were
                // missing or stale, so an app-open no longer costs two KNS round trips.
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
        }
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        // Kaspa logo + bold, matching the KaPosts/Chats balance style.
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: "\(exact) \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .onTapGesture {
            guard sompi != nil else { return }
            UIPasteboard.general.string = exact
            Haptics.success()
            showToast("Balance copied to clipboard.")
        }
    }

    /// Account name sitting right up against the bold Profile title - tap the pencil to
    /// rename in place (renaming used to live only on the logged-out accounts list).
    private func accountNameRow(_ wallet: Wallet) -> some View {
        HStack(spacing: 8) {
            if isEditingAccountName {
                TextField("Account name", text: $editedAlias)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit { commitAccountRename(wallet) }
                Button {
                    commitAccountRename(wallet)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Text(wallet.alias)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Button {
                    editedAlias = wallet.alias
                    isEditingAccountName = true
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, -8)
    }


    /// Your KNS domains. A top-level row rather than a page inside Edit KNS Profile: your
    /// domains are a thing you own, not a setting of the profile that happens to use one of
    /// them, and burying them two levels down meant nothing about the profile screen suggested
    /// they were there at all.
    @ViewBuilder
    private var yourDomainsSection: some View {
        // Shown for every account, not only ones that already own a domain. Hiding it until a
        // KNS profile existed meant the feature was invisible to exactly the people who had not
        // found it yet, and the list itself has an empty state and an inscribe path - so there
        // is something to do on the other side of the row even at zero domains.
        if let walletAddress = knsProfileInfo?.address ?? walletManager.currentWallet?.publicAddress {
            NavigationLink {
                KNSDomainsListView(
                    walletAddress: walletAddress,
                    domains: knsDomains,
                    primaryDomain: knsPrimaryDomain,
                    settingPrimaryDomainId: settingPrimaryDomainId,
                    setPrimaryError: $setPrimaryMessage,
                    onSetPrimary: { domain in
                        Task { await setPrimaryDomain(domain) }
                    },
                    onInscribeComplete: { result in
                        Haptics.success()
                        showToast(localizedFormat("Inscribe submitted for %@.", result.domain))
                        Task { await refreshKNSData(for: walletAddress) }
                    },
                    onTransferComplete: { result in
                        Haptics.success()
                        let message = result.verified
                            ? localizedFormat("%@ transferred to %@.", result.domain, result.recipientAddress)
                            : localizedFormat("Transfer submitted for %@.", result.domain)
                        showToast(message)
                        Task { await refreshKNSData(for: walletAddress) }
                    },
                    onRefresh: { await refreshKNSDomainsOnly(for: walletAddress) },
                    onCustomizeProfile: { domain in
                        openDomainProfileEditor(domain, walletAddress: walletAddress)
                    }
                )
            } label: {
                HStack {
                    Label("Your Domains", systemImage: "at")
                        .foregroundColor(.primary)
                    Spacer()
                    // Every name the account owns: .kachat, KNS, .k and .kaspa.
                    Text("\(kachatOwnedCount + knsDomains.count + (nameServices.ownerAddress == walletAddress.lowercased() ? nameServices.totalOwned : 0))")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(glassBackground(cornerRadius: 18))
            // The .k and .kaspa lookups, so the count above includes them before the list opens.
            .task(id: walletAddress) {
                await NameServicesClient.shared.refresh(for: walletAddress)
            }
            // Reloads whenever the registry moves (a registration, sale or transfer lands).
            .task(id: "\(walletAddress)-\(kachatRegistry.revision)") {
                await loadKachatOwnedCount(walletAddress)
            }
        }
    }

    private func loadKachatOwnedCount(_ address: String) async {
        guard KachatNamesService.isLaunched, let key = KachatNamesRegistry.keyOf(address) else {
            kachatOwnedCount = 0
            return
        }
        await kachatRegistry.refreshIfStale(maxAge: 300)
        // the same names Your Domains lists: a lapsed one isn't yours any more
        guard let names = try? await kachatRegistry.heldNames(owner: key) else { return }
        kachatOwnedCount = names.count
        // and one that lapses while Profile is open comes off the count right then
        await kachatRegistry.dropLapsed(from: names) { kachatOwnedCount = $0.count }
    }

    /// Settings, as a card in the list rather than a glyph in the chrome - it belongs with the
    /// other destinations you tap into from here (Your Domains, Help), and it is the entry point
    /// to everything the app can be configured to do.
    private var settingsSection: some View {
        Button {
            showSettings = true
        } label: {
            HStack {
                Label("Settings", systemImage: "gear")
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

    /// Entry to the Help screen: every guide in one place.
    private var helpSection: some View {
        NavigationLink {
            ProfileHelpView(
                onWelcomeGuide: { showWelcomeGuideReplay = true },
                onKNSSetupGuide: { showKachatSetupGuide = true }
            )
        } label: {
            HStack {
                Label("Help", systemImage: "questionmark.circle")
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

    private func commitAccountRename(_ wallet: Wallet) {
        let trimmed = editedAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingAccountName = false
        guard !trimmed.isEmpty, trimmed != wallet.alias,
              let account = walletManager.savedAccounts.first(where: { $0.publicAddress == wallet.publicAddress })
        else { return }
        walletManager.renameSavedAccount(account, to: trimmed)
        showToast("Account renamed.")
    }

    /// KaPosts-style hero: KNS banner (gradient fallback), overlapping avatar, display name and
    /// bio. The name is what other people see you as: your domain name, else your short address
    /// ("kaspa:xxxx....xxxx") - never the account name, which is only your own label for it.
    /// Testnet only: the `.kachat` label of the wallet's address (nil on mainnet, or without one).
    private func loadKachatLabel(_ address: String) async {
        guard KachatNamesService.isEnabled else {
            kachatLabel = nil
            kachatAvatarSource = nil
            kachatBannerSource = nil
            kachatBioSource = nil
            kachatLinktree = nil
            return
        }
        await kachatRegistry.refreshIfStale(maxAge: 300)
        // a profile saved on another device since this one's last save replaces the local copy
        await kachatRegistry.syncOwnProfile(address: address)
        let identity = try? await kachatRegistry.identity(address: address)
        kachatLabel = identity?.label
        let profile = kachatRegistry.ownProfile(for: address)?.profile ?? identity?.profile
        kachatAvatarSource = profile?.avatar
        kachatBannerSource = profile?.banner
        kachatBioSource = profile?.bio
        kachatLinktree = profile?.linktree
    }

    private func profileHeroSection(_ wallet: Wallet) -> some View {
        let displayName: String = {
            if KachatNamesService.isEnabled, let kachatLabel {
                return "\(kachatLabel).kachat"
            }
            // Your .kas name is yours to manage in Your Domains, but not your name here since 5.2
            // (KNSService.showsDomainNamesAsIdentity) - that will be your .kachat name.
            if KNSService.showsDomainNamesAsIdentity,
               let domain = knsPrimaryDomain ?? knsProfileInfo?.domainName,
               !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return KaPostsView.displayKasName(domain)
            }
            return Contact.generateDefaultAlias(from: wallet.publicAddress)
        }()
        // On testnet the .kachat profile (avatar, banner and bio looked up from its social link)
        // comes first; the KNS one otherwise.
        let kachatBanner = socialImages.profile(for: kachatBannerSource)?.banner
        let kachatAvatar = socialImages.profile(for: kachatAvatarSource)?.avatar
        let kachatBio = socialImages.profile(for: kachatBioSource)?.bio
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if let kachatBanner {
                    KNSBannerImageView(bannerURLString: kachatBanner, height: 140, cornerRadius: 0, fitsWidth: true)
                } else if !KachatNamesService.isEnabled, let bannerURL = knsProfileInfo?.profile?.bannerUrl,
                   KNSProfileLinkBuilder.websiteURL(from: bannerURL) != nil {
                    KNSBannerImageView(bannerURLString: bannerURL, height: 140, cornerRadius: 0, fitsWidth: true)
                } else {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 140)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            // Avatar overlaps the banner; the Edit/Create entry sits beside it, bottom-aligned
            // so the text lands fully below the banner. This hero is only ever built for the
            // user's own wallet (ProfileView renders walletManager.currentWallet), so the edit
            // affordance never shows on someone else's profile.
            HStack(alignment: .bottom) {
                KNSAvatarView(
                    // On testnet identity is .kachat only; KNS pictures aren't shown there.
                    avatarURLString: KachatNamesService.isEnabled ? kachatAvatar : knsProfileInfo?.avatarURL,
                    fallbackText: displayName,
                    size: 76
                )
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                Spacer()
                Button {
                    showKNSEditor = true
                } label: {
                    // KaChat's own profile. .kas profiles are customized per domain in Your
                    // Domains instead; the app no longer shows them.
                    Text("Edit KaChat Profile")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, -38)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let bio = kachatBio {
                    Text(verbatim: bio)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if !KachatNamesService.isEnabled, let bio = knsProfileInfo?.profile?.bio,
                   !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let linktree = kachatLinktree, let url = URL(string: linktree) {
                    Link(destination: url) {
                        Label {
                            Text(verbatim: linktree.replacingOccurrences(of: "https://", with: ""))
                        } icon: {
                            Image(systemName: "link")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .background(glassBackground(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Single source of truth for "does this wallet have a KNS profile at all?" - a registered
    /// domain is what the editor needs (see `showKNSEditor`'s `assetId != nil` guard), so the same
    /// predicate decides both the destination (editor vs. guided creation flow) and the wording of
    /// every affordance that offers it. Reads `knsProfileInfo` (@State, refreshed by
    /// `refreshKNSData`) so the label flips from "Create" to "Edit" as soon as a profile is
    /// created - no app restart required.
    private var hasKNSProfile: Bool {
        !(knsProfileInfo?.domainName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setPrimaryDomain(_ domain: KNSDomain) async {
        guard settingPrimaryDomainId == nil else { return }
        guard let walletAddress = walletManager.currentWallet?.publicAddress else {
            await MainActor.run {
                setPrimaryMessage = KNSSetPrimaryMessage(
                    text: localized("Wallet not available."),
                    isError: true
                )
            }
            return
        }

        let assetId = domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty else {
            await MainActor.run {
                setPrimaryMessage = KNSSetPrimaryMessage(
                    text: localized("KNS domain id is missing."),
                    isError: true
                )
            }
            return
        }

        await MainActor.run {
            settingPrimaryDomainId = assetId
            // Clear any previous failure so a retry does not sit under a stale error.
            setPrimaryMessage = nil
        }
        logKNSWrite("SET_PRIMARY_START domain=\(domain.fullName) asset=\(assetId)")

        do {
            try await submitSetPrimaryDomainWithSignatureFallback(domainId: assetId)
            await MainActor.run {
                knsPrimaryDomain = domain.fullName
            }
            await refreshKNSUntilPrimarySettles(address: walletAddress, expected: domain.fullName)
            await MainActor.run {
                settingPrimaryDomainId = nil
                Haptics.success()
                // No message on success: the star moves to this domain the moment the write
                // lands, which is the confirmation. A popup on top of that is noise.
                setPrimaryMessage = nil
                showToast(localizedFormat("Primary domain set to %@.", domain.fullName))
            }
            logKNSWrite("SET_PRIMARY_SUCCESS domain=\(domain.fullName)")
        } catch {
            logKNSWrite("SET_PRIMARY_FAIL domain=\(domain.fullName) \(diagnosticError(error))")
            let message = compactErrorText(error)
            await MainActor.run {
                settingPrimaryDomainId = nil
                Haptics.impact(.medium)
                setPrimaryMessage = KNSSetPrimaryMessage(text: message, isError: true)
            }
        }
    }

    /// Refreshes until KNS actually reports the new primary, or the attempts run out.
    ///
    /// A KNS profile belongs to a domain, so the avatar, banner and details all change with the
    /// primary - but the write has only just been submitted, and one immediate refresh often
    /// races the indexer and reads back the OLD primary. That left the editor showing the
    /// previous domain's profile until it was closed and reopened. Bounded, and it keeps whatever
    /// the last refresh produced either way, so a slow indexer costs a stale screen rather than a
    /// hang.
    private func refreshKNSUntilPrimarySettles(address: String, expected: String) async {
        let expectedKey = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await refreshKNSData(for: address)
            // Read on the main actor like every other access to this state - refreshKNSData has
            // just written it from there.
            let settled = await MainActor.run {
                (knsPrimaryDomain ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == expectedKey
            }
            if settled { return }
        }
    }

    private func refreshKNSData(for address: String) async {
        await MainActor.run {
            isLoadingKNS = true
        }
        // Forced on purpose: every caller of this is a post-write refresh (inscribe, transfer,
        // set-primary, the setup guide), and `refreshKNSUntilPrimarySettles` above relies on
        // each round actually re-asking the indexer - a cache-first fetch would hand back the
        // stale primary three times over and never settle.
        if let info = await KNSService.shared.fetchInfo(for: address, force: true) {
            await MainActor.run {
                knsDomains = info.allDomains
                knsPrimaryDomain = info.primaryDomain
            }
        }
        if let profileInfo = await KNSService.shared.fetchProfile(for: address, force: true) {
            await MainActor.run {
                knsProfileInfo = profileInfo
            }
        }
        await MainActor.run {
            isLoadingKNS = false
        }
    }

    /// Pull-to-refresh on the Domains list (several navigation levels below this root Profile
    /// view) only ever needs the domain/primary-domain data itself - unlike `refreshKNSData`,
    /// this skips the `isLoadingKNS` toggle and the extra profile-fetch round trip, both of which
    /// were making that gesture feel laggy: mutating `isLoadingKNS` here forces this whole (large)
    /// root view's body to recompute while the user is mid-gesture on a pushed screen, and the
    /// profile fetch isn't shown anywhere on the Domains list anyway.
    private func refreshKNSDomainsOnly(for address: String) async {
        guard let info = await KNSService.shared.fetchInfo(for: address) else { return }
        await MainActor.run {
            knsDomains = info.allDomains
            knsPrimaryDomain = info.primaryDomain
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
                    cornerRadius: 0,
                    fitsWidth: true
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
        // Same predicate as `hasKNSProfile` (this variant is passed the profile explicitly).
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
                                .lineLimit(5)
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
                // A never-used address, resolved on the way in - see freshReceiveAddress. Never
                // substitutes the CHATTING address for the spending role, which was the
                // "chatting balance under spending" flicker; if nothing can be derived this
                // instant (locked keychain) it says so rather than showing the wrong address.
                ReceiveKaspaQRView()
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

    /// Resolves a fresh receive address before drawing the QR, so the code on screen is never
    /// one that has already appeared on chain.
    ///
    /// A view of its own rather than resolving in the NavigationLink's destination builder: that
    /// builder is evaluated eagerly while the row is merely on screen, so any work in it would
    /// run whether or not the user ever taps, and it cannot await.
    /// Also opened from the Chats New sheet ("Receive Kaspa").
    struct ReceiveKaspaQRView: View {
        @EnvironmentObject private var walletManager: WalletManager
        @State private var address: String?
        @State private var resolving = true
        @State private var balanceSompi: UInt64?

        var body: some View {
            Group {
                if let address {
                    ChattingAddressQRView(
                        address: address,
                        balanceSompi: balanceSompi,
                        subtitle: "A fresh address, never used before. Kaspa sent here lands in this account and shows in your spending total. This address should be used for everything not related to chatting or domains."
                    )
                } else if resolving {
                    ProgressView("Preparing a fresh address")
                        .font(.subheadline)
                        .padding()
                } else {
                    Text("Spending address is unlocking — go back and try again.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .task {
                guard address == nil else { return }
                // Warmed on Profile's appear - when it is there this screen draws immediately,
                // and the check below is a no-op re-confirmation rather than something the user
                // waits behind.
                if let warmed = ReceiveAddressWarmCache.address {
                    address = warmed
                    resolving = false
                }
                let resolved = await walletManager.freshReceiveAddress()
                // Only swap if the warmed answer went stale between warming and opening. A QR is
                // scanned the instant it appears, so it must not change under a pointed camera
                // for any lesser reason.
                if resolved != address { address = resolved }
                ReceiveAddressWarmCache.address = resolved
                resolving = false
                guard let resolved else { return }
                // A failed lookup leaves the balance unknown (nothing shown) rather than 0 KAS.
                if let utxos = try? await NodePoolService.shared.getUtxosByAddresses([resolved]) {
                    balanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
                }
            }
        }
    }

    private var qrCircleIcon: some View {
        Image(systemName: "qrcode")
            .font(.scaled(size: 26, weight: .medium))
            .foregroundColor(.black)
            .frame(width: 80, height: 80)
            .background(Circle().fill(Color.accentColor))
    }

    // MARK: - Address action rows (Chatting Address / Spending Address)

    /// Two single-line rows, one per address role, sitting directly on the screen background
    /// (no card) - same treatment as the big QR buttons above them. Each shows the role title
    /// and balance on the left and three large icon-only buttons on the right: Copy, Send,
    /// Manage. Replaces the old expanding dropdowns that hid the same three actions behind a
    /// chevron tap.
    private func addressDropdownsSection(_ wallet: Wallet) -> some View {
        VStack(spacing: 20) {
            // Testnet only: free TN10 coins for the chatting address, from the official faucet.
            if AppSettings.load().networkType == .testnet {
                TestnetFaucetClaimButton(address: wallet.publicAddress)
            }
            addressActionRow(
                title: "Chatting",
                address: wallet.publicAddress,
                balanceText: wallet.balanceSompi.map { "\(formatKaspaExact($0)) \(KaspaUnit.symbol)" },
                onSend: { showWithdrawSheet = true }
            ) {
                ChattingAddressManageView(address: wallet.publicAddress)
            }
            addressActionRow(
                title: "Spending",
                address: walletManager.currentSpendingAddress(),
                balanceText: spendingAddressBalanceSompi.map { "\(formatKaspaExact($0)) \(KaspaUnit.symbol)" },
                totalText: spendingTotalText,
                isLoadingBalance: isLoadingSpendingBalance,
                onSend: { showSpendingAddressWithdraw = true }
            ) {
                ManageAddressesView()
            }
        }
    }

    /// One address row: role title + balance on the left, three large icon-only circles on
    /// the right (Copy, Send, Manage - the icons alone carry the meaning; VoiceOver reads the
    /// accessibility labels). No shortened address, no card background - the row sits on the
    /// screen background like the QR buttons. `address` is optional because the current
    /// spending address can be momentarily unresolvable while the keychain unlocks; in that
    /// state a small "Address unlocking..." note shows and the Copy and Send actions are
    /// inert guards rather than the wrong address.
    private func addressActionRow<Destination: View>(
        title: String,
        address: String?,
        balanceText: String?,
        /// Optional second line under the balance. Used by the Spending row for the whole-account
        /// total; the Chatting row has one address, so there is no total to distinguish.
        totalText: String? = nil,
        isLoadingBalance: Bool = false,
        onSend: @escaping () -> Void,
        @ViewBuilder manageDestination: @escaping () -> Destination
    ) -> some View {
        // Two buttons instead of three now, so the row centers as one cluster instead of
        // splitting to the screen edges.
        HStack(spacing: 24) {
            // The title + balance block IS the copy affordance: tapping it copies the
            // address, replacing the old dedicated Copy button.
            Button {
                guard let address else { return }
                UIPasteboard.general.string = address
                Haptics.success()
                showToast(address.addressCopiedToastText)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if address == nil {
                        Text("Address unlocking...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if isLoadingBalance {
                        ProgressView()
                            .scaleEffect(0.6, anchor: .leading)
                            .frame(height: 14, alignment: .leading)
                    } else if let balanceText {
                        Text(balanceText)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                        if let totalText {
                            Text(totalText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                // Fixed width so the Send/Manage buttons land in the same column on both
                // cards regardless of title and balance text width.
                .frame(width: 140, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Copy \(title) address"))
            addressRowIconButton(icon: "arrow.up.circle.fill", label: "Send") {
                guard address != nil else { return }
                onSend()
            }
            NavigationLink {
                manageDestination()
            } label: {
                addressRowIconLabel(icon: "gearshape", label: "Manage")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(glassBackground(cornerRadius: 18))
    }

    private func addressRowIconButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            addressRowIconLabel(icon: icon, label: label)
        }
        .buttonStyle(.plain)
    }

    /// A large icon-only circle, no caption - the caption text became the accessibility label.
    private func addressRowIconLabel(icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.scaled(size: 22, weight: .medium))
            .foregroundColor(.accentColor)
            .frame(width: 54, height: 54)
            .background(Circle().fill(.regularMaterial))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
            .contentShape(Circle())
            .accessibilityLabel(Text(label))
    }

    /// The whole-account total, shown whenever it is known.
    ///
    /// Deliberately NOT hidden when it matches the balance above it. On a wallet whose funds all
    /// sit on the current address the two ARE the same number, and hiding the line then is
    /// exactly when its absence is most confusing - it reads as the feature being missing rather
    /// than as "nothing else to add".
    private var spendingTotalText: String? {
        guard let total = spendingTotalSompi else { return nil }
        return "Total: \(formatKaspaExact(total)) \(KaspaUnit.symbol)"
    }

    /// Coalesces balance refreshes triggered by own-address activity.
    ///
    /// A single send fires several of these - the spend, its change, and the acceptance - and
    /// BOTH notifications fire for the same event, so an un-coalesced handler ran the refresh
    /// half a dozen times in a couple of seconds. Each run is a balance fetch plus a UTXO fetch
    /// over every spending address, on the same actor driving the send sheet's keyboard, which
    /// is why sending felt heavy. One refresh, shortly after the burst stops, says the same
    /// thing.
    private func scheduleBalanceRefresh() {
        balanceRefreshTask?.cancel()
        balanceRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await walletManager.refreshBalance(force: true)
            guard !Task.isCancelled else { return }
            await loadSpendingAddressBalance()
        }
    }

    /// Decides the Receive QR's address ahead of the tap and hands it to the shared cache, so
    /// opening the sheet is a read rather than a round trip.
    private func warmReceiveAddress() async {
        guard let address = await walletManager.freshReceiveAddress() else { return }
        ReceiveAddressWarmCache.address = address
        ProfileQRCodeCache.preload(address: address, completion: nil)
    }

    private func loadSpendingAddressBalance() async {
        guard let address = walletManager.currentSpendingAddress() else {
            // Unresolvable this instant — show "—" rather than leaving a stale number on screen.
            spendingAddressBalanceSompi = nil
            isLoadingSpendingBalance = false
            return
        }
        isLoadingSpendingBalance = true
        // A failed lookup keeps the last known figure (or the dash) rather than printing 0 KAS.
        if let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address]) {
            spendingAddressBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        } else {
            AppLog.log("%@", "[Contacts] Spending balance refresh failed; keeping the last known figure")
        }
        isLoadingSpendingBalance = false

        // The whole set, in ONE call - a per-address loop would be dozens of requests on a wallet
        // that has been used, and the node takes the list.
        let all = walletManager.allSpendingAddresses()
        guard !all.isEmpty else {
            spendingTotalSompi = nil
            return
        }
        // A failure leaves the previous total in place rather than clearing it. A line that
        // vanishes because one request timed out reads as the feature being broken; a total a
        // few seconds stale does not.
        if let allUtxos = try? await NodePoolService.shared.getUtxosByAddresses(all) {
            spendingTotalSompi = allUtxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
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
                    showDonateSheet = true
                } label: {
                    HStack {
                        Text("Donate")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: Self.donateName)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 16)
                Button {
                    showOpenSourceLicenses = true
                } label: {
                    HStack {
                        Text("Open Source Licenses")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(glassBackground(cornerRadius: 18))
        }
        .sheet(isPresented: $showOpenSourceLicenses) {
            OpenSourceLicensesView()
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
        // Half sheet rather than a confirmation dialog, matching every other chooser in the app -
        // and it gives the consequence a row of its own beside the action, which a dialog of bare
        // verbs under a grey line cannot.
        .sheet(isPresented: $showLogoutConfirmation) {
            ConfirmActionSheet(
                title: "Log Out",
                confirmTitle: "Log Out",
                confirmSubtitle: "Signs out of this account. Wallet and message data stay on this device.",
                confirmSystemImage: "rectangle.portrait.and.arrow.right"
            ) {
                Task { await walletManager.logout() }
            }
        }
    }

    /// "5.0 (1)" through the beta cycle, plain "5.0" once the train is released. The build
    /// number here is OURS - `KaChatBuildNumber` from Version.xcconfig, bumped per beta - not
    /// CFBundleVersion, which Xcode Cloud overwrites in the archive with its own ever-rising
    /// counter (that number still travels in diagnostics archives, where matching the upload
    /// matters). `KaChatIsRelease` = YES drops the parenthetical for the App Store build.
    private var appVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return "Unknown" }
        let isRelease = ((info?["KaChatIsRelease"] as? String) ?? "").uppercased() == "YES"
        let build = (info?["KaChatBuildNumber"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isRelease || build.isEmpty {
            return version
        }
        return "\(version) (\(build))"
    }

    /// Next to the Profile title: a kachat.app link to you. Anywhere it is pasted it previews
    /// with your KNS name and avatar; tapped with KaChat installed it opens a chat with you
    /// (or the new-chat screen, for someone who has not got you as a contact); without it,
    /// the page offers the download.
    @ViewBuilder
    private var profileShareButton: some View {
        if let address = walletManager.currentWallet?.publicAddress,
           let url = KaChatInternalLink.profileShareURL(for: address) {
            // The link and nothing else, built by the same call as User Info > Share: it
            // previews with your name and avatar on its own.
            // (`preview` only titles the share sheet; it is not part of what gets pasted.)
            ShareLink(
                item: url,
                preview: SharePreview((KNSService.showsDomainNamesAsIdentity ? knsPrimaryDomain : nil) ?? "My KaChat profile", image: Image("KaspaLogo"))
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
            }
            .accessibilityLabel("Share your profile")
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
            "message=\(UserFacingError.message(for: error))",
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

    /// Loads one .kas domain's profile and opens the editor for it. The fetch is the editor's
    /// own (`fetchDomainProfileForEditing`): the app no longer caches or shows .kas profiles.
    private func openDomainProfileEditor(_ domain: KNSDomain, walletAddress: String) {
        Task {
            let profile = await KNSService.shared.fetchDomainProfileForEditing(assetId: domain.inscriptionId)
            domainProfileEdit = DomainProfileEditTarget(info: KNSAddressProfileInfo(
                address: walletAddress,
                domainName: domain.fullName,
                assetId: domain.inscriptionId,
                profile: profile,
                fetchedAt: Date()
            ))
        }
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

    /// Banner's Retry: replays every failed field sequentially through the same single-field
    /// retry path (which itself updates isSavingKNSProfile/progress, so the banner shows the
    /// per-field progress again).
    private func retryAllFailedKNSUpdates() {
        guard let profileInfo = knsProfileInfo,
              let assetId = profileInfo.assetId, !assetId.isEmpty else { return }
        let pending = failedKNSUpdates
        Task {
            for (key, value) in pending {
                await retryFailedKNSField(
                    key: key,
                    value: value,
                    assetId: assetId,
                    domainName: profileInfo.domainName
                )
            }
        }
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

/// The Receive QR's address, decided ahead of the tap.
///
/// A plain box rather than state on a view: the value is warmed by the Profile screen and read
/// by the QR screen, which is presented by a NavigationLink and so has no chance to run anything
/// before its first frame. Process-lifetime only - it is a head start, never a source of truth,
/// and `freshReceiveAddress` re-confirms it on every open.
enum ReceiveAddressWarmCache {
    @MainActor static var address: String?
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

/// The outcome of a "Set as Primary" tap, shown INSIDE the editor sheet.
///
/// The operation is owned by ContactsView, which reports through `showToast` - and a toast is
/// drawn in ContactsView's own hierarchy, which sits BEHIND a presented sheet. So the star's every
/// outcome, success and failure alike, was invisible to someone looking at the sheet: tapping it
/// appeared to do nothing whether the write landed or not.
private struct KNSSetPrimaryMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

private struct KNSProfileEditorSheet: View {
    let profileInfo: KNSAddressProfileInfo
    let onSave: (KNSProfileEditorSubmission) -> Void
    // Bindings, not snapshots: this sheet is presented with `.sheet(isPresented:)`, whose content
    // is built from the values captured when it opened. As plain lets, the in-flight spinner never
    // started and the star never moved to the newly-set primary, so the row looked inert.
    @Binding var domains: [KNSDomain]
    @Binding var primaryDomain: String?
    @Binding var settingPrimaryDomainId: String?
    @Binding var setPrimaryMessage: KNSSetPrimaryMessage?
    let onSetPrimary: (KNSDomain) -> Void
    let onInscribeComplete: (KNSDomainInscribeResult) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    let onRefreshDomains: () async -> Void

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    /// Observed so this screen follows the profile as it changes underneath it. A KNS profile
    /// belongs to a DOMAIN, so promoting a different domain to primary swaps which avatar, banner
    /// and details are in effect - and `profileInfo` is the snapshot taken when the sheet opened,
    /// which would keep showing the old domain's until the sheet was closed and reopened.
    @ObservedObject private var knsService = KNSService.shared
    @State private var showSaveConfirmation = false
    /// Identity of the profile the editable fields were last seeded from, so a refresh that
    /// returns the SAME profile never overwrites what the user is part-way through typing.
    @State private var seededProfileIdentity: String?

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
        domains: Binding<[KNSDomain]>,
        primaryDomain: Binding<String?>,
        settingPrimaryDomainId: Binding<String?>,
        setPrimaryMessage: Binding<KNSSetPrimaryMessage?>,
        onSetPrimary: @escaping (KNSDomain) -> Void,
        onInscribeComplete: @escaping (KNSDomainInscribeResult) -> Void,
        onTransferComplete: @escaping (KNSDomainTransferResult) -> Void,
        onRefreshDomains: @escaping () async -> Void,
        onSave: @escaping (KNSProfileEditorSubmission) -> Void
    ) {
        self.profileInfo = profileInfo
        self._domains = domains
        self._primaryDomain = primaryDomain
        self._settingPrimaryDomainId = settingPrimaryDomainId
        self._setPrimaryMessage = setPrimaryMessage
        self.onSetPrimary = onSetPrimary
        self.onInscribeComplete = onInscribeComplete
        self.onTransferComplete = onTransferComplete
        self.onRefreshDomains = onRefreshDomains
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

    /// The profile as it stands NOW, falling back to the opening snapshot until the cache has an
    /// entry for this address.
    private var liveProfileInfo: KNSAddressProfileInfo {
        // The cache holds the PRIMARY domain's entry, and since 5.2 no profile at all
        // (KNSService.loadsDomainProfiles). Editing any one domain from Your Domains must read
        // the profile it was opened with, or the fields would be wiped by the cache's empty one.
        guard KNSService.loadsDomainProfiles,
              let cached = knsService.profileCache[profileInfo.address],
              cached.assetId == profileInfo.assetId else { return profileInfo }
        return cached
    }

    /// Changes when the effective profile changes domain - which is exactly when the fields below
    /// need to be re-read, and only then.
    private var profileIdentity: String {
        let info = liveProfileInfo
        return [info.assetId, info.domainName].map { $0 ?? "" }.joined(separator: "|")
    }

    /// Re-reads every editable field from `info`.
    ///
    /// Also drops any staged avatar/banner upload: those were picked for the previous domain's
    /// profile, and silently carrying them onto a different one would save the wrong images.
    private func seedFields(from info: KNSAddressProfileInfo) {
        let profile = info.profile ?? .empty
        avatarUrl = profile.avatarUrl ?? ""
        bannerUrl = profile.bannerUrl ?? ""
        bio = profile.bio ?? ""
        x = profile.x ?? ""
        website = profile.website ?? ""
        telegram = profile.telegram ?? ""
        discord = profile.discord ?? ""
        contactEmail = profile.contactEmail ?? ""
        github = profile.github ?? ""
        redirectUrl = profile.redirectUrl ?? ""

        avatarUploadData = nil
        avatarUploadMimeType = nil
        avatarPreviewImage = nil
        avatarPickerItem = nil
        bannerUploadData = nil
        bannerUploadMimeType = nil
        bannerPreviewImage = nil
        bannerPickerItem = nil
        imageLoadError = nil
    }

    private var canSave: Bool {
        !isLoadingAvatar && !isLoadingBanner
    }

    /// Which fields will actually be submitted as their own on-chain commit/reveal transaction if
    /// Save is confirmed - shown in the pre-save confirmation card so the cost is clear before
    /// spending anything. Mirrors Android's identical `pendingChanges` computation in
    /// `EditKnsProfileScreen`.
    private var pendingChanges: [String] {
        let existing = liveProfileInfo.profile
        var changes: [String] = []
        if avatarUploadData != nil {
            changes.append("Avatar")
        } else if avatarUrl.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.avatarUrl ?? "") {
            changes.append(avatarUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Avatar (removed)" : "Avatar")
        }
        if bannerUploadData != nil {
            changes.append("Banner")
        } else if bannerUrl.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.bannerUrl ?? "") {
            changes.append(bannerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Banner (removed)" : "Banner")
        }
        if bio.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.bio ?? "") { changes.append("Bio") }
        if x.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.x ?? "") { changes.append("X") }
        if website.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.website ?? "") { changes.append("Website") }
        if telegram.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.telegram ?? "") { changes.append("Telegram") }
        if discord.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.discord ?? "") { changes.append("Discord") }
        if contactEmail.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.contactEmail ?? "") { changes.append("Email") }
        if github.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.github ?? "") { changes.append("GitHub") }
        if redirectUrl.trimmingCharacters(in: .whitespacesAndNewlines) != (existing?.redirectUrl ?? "") { changes.append("Redirect") }
        return changes
    }

    private var displayName: String {
        guard let raw = liveProfileInfo.domainName else { return "KNS Profile" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KNS Profile" : trimmed
    }

    var body: some View {
        NavigationStack {
            // No setup guide here since 5.2: the guide is .kachat's, in Edit KaChat Profile
            // (`KachatSetupGuideView`). A .kas profile is edited field by field below.
            Form {

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
                            // Overlay, not a child - same reason as `KNSBannerImageView`: the
                            // picked photo is full-resolution, and fill-scaled it would report a
                            // width far past the sheet and stretch the whole form.
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 110)
                                .overlay {
                                    Image(uiImage: bannerPreviewImage)
                                        .resizable()
                                        .scaledToFill()
                                }
                                .clipped()
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
                    if let assetId = liveProfileInfo.assetId, !assetId.isEmpty {
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
            }
            .onAppear { seededProfileIdentity = profileIdentity }
            .onChange(of: profileIdentity) { identity in
                guard identity != seededProfileIdentity else { return }
                seededProfileIdentity = identity
                seedFields(from: liveProfileInfo)
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
                        showSaveConfirmation = true
                    }
                    .disabled(!canSave || pendingChanges.isEmpty)
                }
            }
            .overlay {
                if showSaveConfirmation {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture { showSaveConfirmation = false }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Confirm Changes")
                                .font(.headline)
                                .fontWeight(.bold)
                            Text("\(pendingChanges.count) change\(pendingChanges.count == 1 ? "" : "s"). Each is submitted as its own on-chain transaction from your chatting address:")
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(pendingChanges, id: \.self) { change in
                                    Text("• \(change)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            KaspaUnit.text("Each transaction temporarily uses ~2 KAS; ~1 KAS returns immediately as change, so only the small network fee is a real cost.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Button("Cancel") {
                                    showSaveConfirmation = false
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Confirm") {
                                    showSaveConfirmation = false
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
                                .buttonStyle(.borderedProminent)
                                .tint(.accentColor)
                            }
                            .padding(.top, 4)
                        }
                        .padding(20)
                        .frame(maxWidth: 320)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.regularMaterial)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSaveConfirmation)
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
                imageLoadError = UserFacingError.message(for: error)
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
    /// Set only when a "Set as Primary" attempt FAILED, so the detail screen can say so in place.
    /// Success needs no message: the star moves to the new primary as soon as the write lands.
    @Binding var setPrimaryError: KNSSetPrimaryMessage?
    let onSetPrimary: (KNSDomain) -> Void
    let onInscribeComplete: (KNSDomainInscribeResult) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    let onRefresh: () async -> Void
    var onCustomizeProfile: ((KNSDomain) -> Void)? = nil

    /// Which name service's tab is showing. `.kas` is KNS, the rest come from `NameServicesClient`.
    @State private var selectedTLD: NameServiceTLD = .defaultTab
    @ObservedObject private var nameServices = NameServicesClient.shared

    var body: some View {
        VStack(spacing: 0) {
            // One tab per name ending, KaChat's own first: .kachat (not live yet), KNS (.kas),
            // dotk (.k), Kaspa Names (.kaspa). The same underline tab bar as Chats / Group Chats
            // / Public Chats: bold teal labels, a bar under the selected one.
            UnderlineTabBar(
                tabs: NameServiceTLD.allCases.map { (tab: $0, title: $0.suffix) },
                selection: $selectedTLD
            )

            switch selectedTLD {
            case .kas:
                knsDomainList
            case .k, .kaspa:
                serviceNameList(selectedTLD)
            case .kachat:
                // Live on testnet (the testnet-10 registry); mainnet keeps "coming".
                if KachatNamesService.isEnabled {
                    KachatLiveDomainsTab(walletAddress: walletAddress)
                } else {
                    kachatComingSoon
                }
            }
        }
        .contentShape(Rectangle())
        // A sideways swipe changes the name service, like the Chats / Group Chats pages - so the
        // edge swipe that would leave the screen is switched off here (the back button still
        // works, and the swipe comes back on the screens pushed from this one).
        .simultaneousGesture(domainTabSwipe())
        .swipeBackDisabled()
        .task(id: walletAddress) {
            await nameServices.refresh(for: walletAddress)
        }
        .navigationTitle("Your Domains")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "Get a .kas domain at knsdomains.org" - the pinned button under each outside service's
    /// tab, opening that service's own site. KaChat creates only its own `.kachat` names; the
    /// other services' names are registered with them. Same glass capsule with a teal outline
    /// the in-app Inscribe button had (not the accent fill: the cards above are accent-filled).
    @ViewBuilder
    private func getNameButton(_ tld: NameServiceTLD) -> some View {
        if let url = tld.websiteURL, let site = tld.websiteName {
            Link(destination: url) {
                Text("Get a \(tld.suffix) domain at \(site)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    private func domainTabSwipe() -> some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .global)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Decisively horizontal only, so scrolling the list never trips it.
                guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                let tabs = NameServiceTLD.allCases
                guard let index = tabs.firstIndex(of: selectedTLD) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    if dx < 0, index + 1 < tabs.count {
                        selectedTLD = tabs[index + 1]
                    } else if dx > 0, index > 0 {
                        selectedTLD = tabs[index - 1]
                    }
                }
            }
    }

    // MARK: .kas (KNS)

    private var knsDomainList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if domains.isEmpty {
                    Text("No domains yet.")
                        .foregroundColor(.secondary)
                        .padding(16)
                } else {
                    ForEach(domains, id: \.inscriptionId) { domain in
                        let isPrimary = isPrimaryDomain(domain.fullName)
                        NavigationLink {
                            KNSDomainDetailView(
                                domain: domain,
                                isPrimary: isPrimary,
                                isSetPrimaryAllowed: isSetPrimaryAllowed(domain, isPrimary: isPrimary),
                                isTransferAllowed: isDomainTransferAllowed(domain),
                                settingPrimaryDomainId: settingPrimaryDomainId,
                                setPrimaryError: setPrimaryError?.isError == true ? setPrimaryError?.text : nil,
                                onSetPrimary: onSetPrimary,
                                onTransferComplete: onTransferComplete,
                                onCustomizeProfile: onCustomizeProfile
                            )
                        } label: {
                            KNSDomainCard(domain: domain, isPrimary: isPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await onRefresh()
        }
        .safeAreaInset(edge: .bottom) {
            getNameButton(.kas)
        }
    }

    // MARK: .k and .kaspa

    @ViewBuilder
    private func serviceNameList(_ tld: NameServiceTLD) -> some View {
        let names = nameServices.owned[tld] ?? []
        ScrollView {
            LazyVStack(spacing: 16) {
                if names.isEmpty {
                    VStack(spacing: 10) {
                        if nameServices.loading.contains(tld) && nameServices.owned[tld] == nil {
                            ProgressView()
                        } else if nameServices.failed.contains(tld) {
                            Text("Couldn't reach \(tld.serviceName). Pull down to try again.")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("No \(tld.suffix) names yet.")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(names) { owned in
                        DomainNameCardView(
                            title: owned.display,
                            badge: owned.isProvisional ? String(localized: "Settling") : nil
                        )
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await nameServices.refresh(for: walletAddress)
        }
        .safeAreaInset(edge: .bottom) {
            getNameButton(tld)
        }
    }

    // MARK: .kachat

    private var kachatComingSoon: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "at.circle")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(".kachat names are coming")
                    .font(.headline)
                Text("KaChat's own names will live here: claim one, set it as your name in chats, and share it as your profile link.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
    }

    private func isPrimaryDomain(_ domainName: String) -> Bool {
        let normalizedDomain = domainName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrimary = (primaryDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedDomain == normalizedPrimary
    }

    private func isSetPrimaryAllowed(_ domain: KNSDomain, isPrimary: Bool) -> Bool {
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && !isPrimary
    }

    private func isDomainTransferAllowed(_ domain: KNSDomain) -> Bool {
        let status = domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && status != "listed"
    }
}

/// Teal card matching the app's KNS domain branding - used both as the row style in
/// KNSDomainsListView and as the header of KNSDomainDetailView.
struct KNSDomainCard: View {
    let domain: KNSDomain
    var isPrimary: Bool = false

    var body: some View {
        DomainNameCardView(title: domain.fullName, badge: isPrimary ? String(localized: "Primary") : nil)
    }
}

/// The teal name card, for any name service: the name, and an optional corner badge
/// ("Primary" on KNS, "Settling" on a `.kaspa` name still inside its settling window).
struct DomainNameCardView: View {
    let title: String
    var badge: String? = nil
    /// A small line in the bottom-right corner (Your Domains > .kachat: when it expires).
    var footnote: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 100)
                .overlay(
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 20)
                )

            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let footnote {
                Text(verbatim: footnote)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black.opacity(0.65))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
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
                            Text(verbatim: "\(formatKas(fee)) \(KaspaUnit.symbol)")
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
                feeError = UserFacingError.message(for: error)
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
                    checkError = UserFacingError.message(for: error)
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
                    submitError = UserFacingError.message(for: error)
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

/// Detail screen for a single owned domain - the card itself, primary/status info, and a
/// dedicated Send entry point. Reached by tapping a card in KNSDomainsListView. No transfer
/// history section: KNS only exposes a "currently owned assets" endpoint, and the app's own
/// KNS-transfer tracking is a one-shot chat notification, not a persisted per-domain log, so
/// there's no reliable data source for it yet.
struct KNSDomainDetailView: View {
    let domain: KNSDomain
    let isPrimary: Bool
    let isSetPrimaryAllowed: Bool
    let isTransferAllowed: Bool
    let settingPrimaryDomainId: String?
    /// Why the last "Set as Primary" tap failed, shown inline under the row. Nil when it
    /// succeeded or has not been tried - a success shows itself, since the star moves.
    var setPrimaryError: String? = nil
    let onSetPrimary: (KNSDomain) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    /// Opens the full profile editor for this domain (avatar, banner, bio, links). KaChat does
    /// not SHOW .kas profiles anymore - .kachat profiles take priority - but a .kas domain's own
    /// profile can still be customized here. Nil where the host offers no editor.
    var onCustomizeProfile: ((KNSDomain) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showSendSheet = false

    private var isListed: Bool {
        domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "listed"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                KNSDomainCard(domain: domain, isPrimary: isPrimary)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    HStack {
                        Text("Asset ID")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(domain.inscriptionId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)

                    if let onCustomizeProfile {
                        Divider().padding(.leading, 16)
                        Button {
                            onCustomizeProfile(domain)
                        } label: {
                            HStack {
                                Text("Customize Profile")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "person.crop.circle")
                                    .foregroundColor(.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }

                    if isPrimary {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("Primary Domain")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "star.fill")
                                .foregroundColor(.accentColor)
                        }
                        .padding(16)
                    } else if isSetPrimaryAllowed {
                        Divider().padding(.leading, 16)
                        Button {
                            onSetPrimary(domain)
                        } label: {
                            HStack {
                                Text("Set as Primary")
                                    .foregroundColor(.primary)
                                Spacer()
                                if settingPrimaryDomainId == domain.inscriptionId {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "star")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(settingPrimaryDomainId != nil)
                        .padding(16)

                        if let setPrimaryError, settingPrimaryDomainId == nil {
                            // In place rather than as a popup. A failure has to be visible
                            // somewhere: the operation is owned by the Profile screen, and the
                            // toast it raises is drawn behind this sheet where nobody sees it.
                            Text(setPrimaryError)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }

                    if isListed {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("Status")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Listed")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                    }
                }
                .background(glassBackground(cornerRadius: 18))
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showSendSheet = true
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .disabled(!isTransferAllowed)
            .opacity(isTransferAllowed ? 1 : 0.5)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .navigationTitle(domain.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSendSheet) {
            KNSDomainSendView(domain: domain) { result in
                showSendSheet = false
                onTransferComplete(result)
                dismiss()
            }
        }
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

/// Sends (transfers) a single KNS domain inscription to a recipient address or KNS domain -
/// same UX conventions as the app's KAS send flows (KNS-domain-aware recipient, editable
/// network fee) but with no amount field or coin control, since a domain transfer moves the
/// whole inscription rather than a chosen KAS amount. Not `private`: ManageAddressesView's
/// per-spending-address "KNS Domains" tab reuses this exact sheet, passing
/// `spendingAddressIndex` so the transfer is owned/funded/signed by that spending address's
/// derived key instead of the identity/chatting address.
struct KNSDomainSendView: View {
    let domain: KNSDomain
    /// When non-nil, the domain lives on this spending-chain address index and the transfer
    /// spends/signs from that address's own derivation (see KNSDomainTransferService).
    var spendingAddressIndex: Int? = nil
    let onComplete: (KNSDomainTransferResult) -> Void

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var showQRScanner = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var result: KNSDomainTransferResult?
    /// Where the transfer has got to. A commit, a wait, then a reveal is most of a minute, and a
    /// toolbar spinner through all of it is indistinguishable from being stuck.
    @State private var transferStage: KNSDomainTransferService.TransferStage?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?
    private let knsService = KNSService.shared

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    private let baseFeeSompi: UInt64 = 2_000_000

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as WithdrawKaspaView.effectiveAddress.
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    private var priorityFeeSompi: UInt64 {
        if let customFeeSompi { return customFeeSompi }
        return baseFeeSompi * feeTier.multiplier
    }

    private var canSend: Bool {
        hasValidRecipient && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain") {
                    Text(domain.fullName)
                        .fontWeight(.semibold)
                    Text(domain.inscriptionId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section {
                    TextField("kaspa:qr... or domain", text: $addressInput)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: addressInput) { handleInputChange($0) }

                        AddressResolutionCard(address: resolvedAddress ?? (isValidAddress ? addressInput.trimmingCharacters(in: .whitespacesAndNewlines) : nil), domain: resolvedDomain)

                    if !addressInput.isEmpty {
                        if isResolvingKNS {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Looking up domain...")
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
                                Text(verbatim: KaspaAddress.validityText(addressInput, isValid: isValidAddress))
                                    .font(.caption)
                                    .foregroundColor(isValidAddress ? .green : .red)
                            }
                        }
                        if !isResolvingKNS {
                            OtherDomainsDropdown(resolutions: nameResolutions, selected: selectedTLD, onSelect: selectResolution)
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
                    Text("Enter a Kaspa address (kaspa:...) or a domain. .kachat names are looked up first.")
                }

                Section {
                    Picker("Fee", selection: $feeTier) {
                        ForEach(WithdrawFeeTier.allCases) { tier in
                            Text(tier.rawValue).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: feeTier) { _ in
                        customFeeSompi = nil
                        isEditingFee = false
                    }

                    HStack {
                        Text("Network Fee")
                        Spacer()
                        if isEditingFee {
                            TextField("0.00", text: $customFeeText)
                                .keyboardType(.decimalPad)
                                .numericKeyboardDoneButton()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                .onSubmit { commitCustomFee() }
                            Button {
                                commitCustomFee()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button {
                                startEditingFee()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(verbatim: "\(trimmedKas(priorityFeeSompi)) \(KaspaUnit.symbol)")
                                        .underline()
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Fee")
                } footer: {
                    Text("If the network is busy, Fast or Priority pays a higher fee to help your transfer confirm sooner. Tap the fee amount to set a custom fee.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Send Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Send") {
                            send()
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            // Progress lives in its own sheet rather than a toolbar spinner: the transfer takes
            // long enough that the user needs to be told it is still working, and dismissal is
            // disabled because leaving mid-transfer would hide a running on-chain operation.
            .sheet(isPresented: Binding(
                get: { transferStage != nil },
                set: { if !$0 { transferStage = nil } }
            )) {
                domainTransferProgressSheet
            }
            .sheet(item: Binding(
                get: { result.map { SentTransaction(txId: $0.revealTxId) } },
                set: { if $0 == nil { result = nil } }
            )) { sent in
                SentConfirmationSheet(transaction: sent) {
                    if let result { onComplete(result) }
                    dismiss()
                }
                .presentationDetents([.height(sent.sheetHeight)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
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

    private func startEditingFee() {
        customFeeText = trimmedKas(priorityFeeSompi)
        isEditingFee = true
    }

    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let sompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
        customFeeSompi = sompi
    }

    private func send() {
        isSubmitting = true
        transferStage = .preparing
        errorMessage = nil
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let fee = priorityFeeSompi
        Task {
            do {
                let transferResult = try await KNSDomainTransferService.shared.transferDomain(
                    domain: domain.fullName,
                    assetId: domain.inscriptionId,
                    to: recipient,
                    priorityFeeSompi: fee,
                    fromSpendingAddressIndex: spendingAddressIndex,
                    onProgress: { stage in transferStage = stage }
                )
                await MainActor.run {
                    isSubmitting = false
                    transferStage = nil
                    result = transferResult
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    transferStage = nil
                    errorMessage = UserFacingError.message(for: error)
                    Haptics.impact(.medium)
                }
            }
        }
    }

    @ViewBuilder
    private var domainTransferProgressSheet: some View {
        let stage = transferStage ?? .preparing
        VStack(spacing: 16) {
            Text("Sending \(domain.fullName)")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            ProgressView(value: stage.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text(LocalizedStringKey(stage.title))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("A domain transfer is two transactions, so this takes a moment. Keep the app open until it finishes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .presentationDetents([.height(260)])
        .interactiveDismissDisabled(true)
    }

    private func trimmedKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Transaction history for the chatting (identity) address, reached from its dropdown in
/// Profile. Same pattern as ManageAddressesView's SpendingAddressTransactionHistoryView: tapping
/// a transaction opens it directly on whichever block explorer is selected in Settings >
/// Connection > Kaspa Explorer, rather than showing an in-app detail screen.
/// Full-featured detail screen for the wallet's own chatting/identity address — field-for-field
/// the same screen as ManageAddressesView's SpendingAddressTransactionHistoryView (balance,
/// Transaction History/UTXOs tabs, Compound UTXOs, Export private key, Explorer, Receive/Send),
/// just address-based instead of index-based. Reached from the Profile screen's Chatting Address
/// section's "Manage Address" row.
struct ChattingAddressManageView: View {
    let address: String

    /// The tapped transaction, while its action chooser is up.
    @State private var transactionActionTarget: KaspaFullTransactionResponse?
    @State private var pendingPortfolioCandidate: PortfolioCandidateTransaction?
    /// The transaction being filed into a portfolio, if any - see `AddToPortfolioSheet`.
    @State private var portfolioCandidate: PortfolioCandidateTransaction?
    /// Name of the portfolio just added to, for the confirmation capsule.
    @State private var addedPortfolioName: String?

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private enum Tab: String, CaseIterable {
        case transactions = "History"
        case utxos = "UTXOs"
        case kachatDomains = ".kachat"
    }

    @State private var selectedTab: Tab = .transactions
    @State private var transactions: [KaspaFullTransactionResponse] = []
    /// The last history fetch gave up partway. Kept separate from `transactions.isEmpty` because
    /// the two mean opposite things and used to render identically: a rate-limited request looked
    /// exactly like an address that has never been used.
    @State private var historyIncomplete = false
    @State private var isLoading = false
    @State private var utxos: [UTXO] = []
    @State private var isLoadingUtxos = false
    /// See `CoinControlView.loadError`.
    @State private var utxoLoadError: String?
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
    @State private var showPrivateKeySheet = false
    /// The "Address Actions" half sheet, and the public-key screen it can open.
    @State private var showAddressActions = false
    @State private var showPublicKeySheet = false
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""

    private var balanceSompi: UInt64 {
        utxos.reduce(UInt64(0)) { $0 + $1.amount }
    }

    private func outpointKey(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    /// Plain names - History, UTXOs, .kachat - the way the user asked for them.
    private func tabLabel(_ tab: Tab) -> String {
        tab.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: "\(formatKasExact(balanceSompi)) \(KaspaUnit.symbol)")
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)


            // What used to be two unlabelled glyphs in the navigation bar. A pair of icons has
            // room for no words at all, so neither said what it did, and there was nowhere to put
            // a third thing. Same button and same sheet as Manage Addresses' own Address Actions.
            Button {
                Haptics.impact(.light)
                showAddressActions = true
            } label: {
                Text("Address Actions")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Right above what it switches, the way Chats has it.
            UnderlineTabBar(
                tabs: Tab.allCases.map { (tab: $0, title: tabLabel($0)) },
                selection: $selectedTab
            )

            switch selectedTab {
            case .transactions:
                transactionsList
            case .utxos:
                utxosList
            case .kachatDomains:
                KachatAddressDomainsList(address: address)
            }
        }
        .navigationTitle("Chatting Address")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddressActions) {
            addressActionsSheet
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPublicKeySheet) {
            ChattingAddressPublicKeyView(address: address)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    showReceiveSheet = true
                } label: {
                    Label("Receive", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showSendSheet = true
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .disabled(balanceSompi == 0)
                .opacity(balanceSompi == 0 ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showReceiveSheet) {
            NavigationStack {
                ChattingAddressQRView(address: address, balanceSompi: balanceSompi)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showReceiveSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSendSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi, isCompoundMode: true) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            ChattingAddressPrivateKeyView(address: address)
        }
        .alert(
            "Rename UTXO",
            isPresented: Binding(
                get: { renamingUtxo != nil },
                set: { if !$0 { renamingUtxo = nil } }
            )
        ) {
            TextField("Name", text: $renameUtxoText)
            Button("Save") {
                if let renamingUtxo {
                    WalletManager.shared.setSpendingUtxoLabel(address: address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: address)
            await loadTransactions()
            await loadUtxos()
        }
    }

    /// The half sheet behind "Address Actions". Same shape as Manage Addresses' and Cold
    /// Storage's sheets of the same name, so all three read as the same object.
    private var addressActionsSheet: some View {
        VStack(spacing: 0) {
            Text("Address Actions")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            VStack(spacing: 12) {
                ActionSheetRow(
                    title: "View Private Key",
                    subtitle: "The key that spends this address. Never share it.",
                    systemImage: "key.fill"
                ) {
                    showAddressActions = false
                    // A turn later: presenting straight from a dismissing sheet is dropped.
                    DispatchQueue.main.async {
                        if settingsViewModel.settings.biometricSeedPhraseEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view this address's private key") {
                                showPrivateKeySheet = true
                            }
                        } else {
                            showPrivateKeySheet = true
                        }
                    }
                }
                ActionSheetRow(
                    title: "View Public Key",
                    subtitle: "The public half of this address, for anyone who asks for it.",
                    systemImage: "number"
                ) {
                    showAddressActions = false
                    DispatchQueue.main.async { showPublicKeySheet = true }
                }
                if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: address) {
                    ActionSheetRow(
                        title: "View in Explorer",
                        subtitle: "Opens this address on your chosen block explorer.",
                        systemImage: "globe"
                    ) {
                        showAddressActions = false
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 20)
    }

    private var transactionsList: some View {
        List {
            if isLoading && transactions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if transactions.isEmpty && historyIncomplete {
                // A failed fetch is not an empty history. Saying "No transactions yet." here was
                // a confident answer about someone's money that the app had not actually got.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load transactions.")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await loadTransactions() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                if historyIncomplete {
                    // Some pages landed, some did not. Say so rather than letting a truncated
                    // list read as the whole history.
                    Text("Some transactions could not be loaded. Pull to refresh to try again.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                ForEach(transactions, id: \.transactionId) { tx in
                    Button {
                        Haptics.impact(.light)
                        // Tapping a transaction asks what to do with it. It used to open the
                        // explorer outright, which left "Add to Portfolio" on a swipe and a long
                        // press - both invisible until you already knew they were there.
                        transactionActionTarget = tx
                    } label: {
                        transactionRow(tx)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The menu is a sheet rather than a confirmation dialog so each option can say what it
        // does, and so the transaction it applies to stays on screen while you choose.
        .sheet(item: $transactionActionTarget, onDismiss: {
            // Handing the portfolio sheet over only once this one is fully gone. Presenting a
            // sheet from inside a sheet that is still dismissing drops it on the floor.
            if let pending = pendingPortfolioCandidate {
                pendingPortfolioCandidate = nil
                portfolioCandidate = pending
            }
        }) { tx in
            TransactionActionsSheet(
                transaction: tx,
                address: address,
                onOpenExplorer: { openInExplorer(tx) },
                onAddToPortfolio: { pendingPortfolioCandidate = $0 }
            )
        }
        .sheet(item: $portfolioCandidate) { candidate in
            AddToPortfolioSheet(candidate: candidate) { portfolio in
                addedPortfolioName = portfolio.name
            }
        }
        .overlay(alignment: .bottom) {
            if let addedPortfolioName {
                PortfolioAddedCapsule(portfolioName: addedPortfolioName) {
                    self.addedPortfolioName = nil
                }
            }
        }
        .refreshable {
            await loadTransactions()
        }
    }

    private var utxosList: some View {
        List {
            if utxos.count > 1 {
                Section {
                    Button {
                        showCompoundSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.merge")
                            Text("Compound UTXOs")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Combines all UTXOs at this address into a single one, to reduce the number of inputs a future send needs.")
                }
            }
            if isLoadingUtxos && utxos.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if utxos.isEmpty {
                if let utxoLoadError {
                    UtxoLoadFailureRow(detail: utxoLoadError) {
                        Task { await loadUtxos() }
                    }
                } else {
                    Text("No UTXOs.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                    utxoRow(utxo)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadUtxos()
        }
    }

    private func utxoRow(_ utxo: UTXO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: utxo.isCoinbase ? "cube.fill" : "circle.grid.2x2.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let label = utxoLabels[outpointKey(utxo)], !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
                Text(verbatim: "\(formatKasExact(utxo.amount)) \(KaspaUnit.symbol)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(utxo.outpoint.transactionId):\(utxo.outpoint.index)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if utxo.isCoinbase {
                Text("Coinbase")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            Button {
                renameUtxoText = utxoLabels[outpointKey(utxo)] ?? ""
                renamingUtxo = utxo
            } label: {
                Image(systemName: "pencil")
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func loadUtxos() async {
        isLoadingUtxos = true
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
            utxoLoadError = nil
        } catch {
            // The list keeps what it had; an outage is not an empty address.
            utxoLoadError = UserFacingError.message(for: error)
        }
        isLoadingUtxos = false
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
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(Self.blockTimeFormat))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let info {
                    Text(verbatim: "\(info.isOutgoing ? "-" : "+")\(formatKasExact(info.amountSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(info.isOutgoing ? .red : .green)
                }
                // The network fee this transaction paid (inputs minus outputs).
                if let fee = tx.feeText() {
                    Text(fee)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    /// Built once: `Date.formatted(date:time:)` resolves a fresh style per call, and this runs
    /// for every transaction row on every render of the list.
    private static let blockTimeFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func loadTransactions() async {
        isLoading = true
        // Confirmed live against api.kaspa.org that limit=500 works fine in a single call
        // (~0.7s) - cuts this from up to 4 sequential round trips down to 1.
        let result = await chatService.fetchFullTransactionsResult(for: address, pageSize: 200, maxTransactions: 200)
        transactions = result.transactions
        historyIncomplete = !result.complete
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Private-key reveal for the wallet's own chatting/identity address — mirrors
/// SpendingAddressPrivateKeyView, but reads the wallet's own root private key rather than a
/// derived spending key, since the identity address isn't part of the spending-chain derivation.
/// Gated by `biometricSeedPhraseEnabled` (not `biometricSpendingKeyEnabled`) since this is the
/// wallet's primary key, matching the same higher-stakes gate as Settings > View Seed Phrase.
private struct ChattingAddressPrivateKeyView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.getPrivateKey()?.hexString ?? "Unavailable"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Anyone with this address's private key can spend its funds. Never share it with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if isRevealed {
                    SecureView {
                        Text(privateKeyHex)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        copySensitiveToClipboard(privateKeyHex)
                        Haptics.success()
                        showToast("Private key copied. Clipboard will clear in 30s.")
                    } label: {
                        Label("Copy Private Key Hex", systemImage: "doc.on.doc")
                    }
                    .padding(.top)
                } else {
                    Button {
                        isRevealed = true
                        let token = UUID()
                        revealToken = token
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            if revealToken == token {
                                isRevealed = false
                            }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.largeTitle)
                            Text("Tap to reveal private key")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(60)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Chatting Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    /// Sensitive copy: hard 30s system expiration + localOnly (no Universal Clipboard sync);
    /// the asyncAfter wipe is an in-app belt-and-suspenders clear (see SettingsView's twin).
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
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
}

/// The chatting address's public key, from the Address Actions sheet.
///
/// Nothing is derived or unlocked to show this: a Kaspa P2PK address IS its public key in bech32,
/// so this decodes the address the screen already has. No reveal gate and no clipboard expiry
/// either - unlike the private key alongside it, this is a value you hand out on purpose.
private struct ChattingAddressPublicKeyView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    /// nil only for an address shape that carries no key (script-hash), which the wallet's own
    /// chatting address never is.
    private var publicKeyHex: String? {
        KaspaAddress.publicKey(from: address)?.hexString
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Safe to share", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text("This is the public half of your chatting address. It identifies you and cannot spend anything.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let publicKeyHex {
                    Text(publicKeyHex)
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button {
                        UIPasteboard.general.string = publicKeyHex
                        Haptics.success()
                        showToast("Public key copied")
                    } label: {
                        Label("Copy Public Key", systemImage: "doc.on.doc")
                    }
                } else {
                    Text("This address does not carry a public key.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
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
}

/// Dedicated white-background QR display, matching Android's "Accept Kaspa"/"Chatting Address"
/// QR screen — deliberately uses literal black/white colors rather than adaptive .primary/
/// .secondary, since forcing a white content area regardless of system dark/light mode would
/// otherwise leave semantic text colors resolved for dark mode (and invisible on the white
/// background) unless the whole screen's color scheme were overridden too.
struct ChattingAddressQRView: View {
    let address: String
    let balanceSompi: UInt64?
    var subtitle: String = "This address should be for chatting and domains only. 1 Kaspa is enough for about 500 interactions in the app. Domains cost from 35 to 4,000 Kaspa, depending on the name."

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
                        // Show the whole address, always. A Kaspa address is ~60-66 chars with no
                        // spaces; capping at 2 lines truncated it on narrower screens. Let it wrap
                        // to as many lines as needed and take the vertical space it requires.
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)

                    // Looked up, not shown verbatim - it read English in every language.
                    Text(LocalizedStringKey(subtitle))
                        .font(.subheadline)
                        .foregroundColor(Color.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                        // Its full height always: in a sheet that is still growing (the Chats
                        // New sheet) it otherwise truncated, then re-wrapped and jumped.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)

                    Text("Tap anywhere to copy")
                        .font(.footnote)
                        .foregroundColor(Color.black.opacity(0.4))

                    Spacer()
                    Spacer()
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { copyAddress() }
            .toast(message: toastMessage)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(balanceSompi.map { "\(formatKaspaExact($0)) \(KaspaUnit.symbol)" } ?? "—")
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

    private func copyAddress() {
        UIPasteboard.general.string = address
        Haptics.success()
        showToast(address.addressCopiedToastText)
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
/// Sends a plain KAS transfer from the wallet's chatting (identity) address to an arbitrary
/// recipient address. Reuses AddContactView's address-entry conventions (paste/QR scan,
/// live validation) but with an amount field instead of a contact-name field, since this
/// isn't creating a contact.
struct WithdrawKaspaView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64?
    /// Pre-fills the recipient with `fromAddress` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, matching SpendingAddressWithdrawView's
    /// identical Compound UTXOs behavior.
    var isCompoundMode: Bool = false
    /// Pre-fills the recipient (Address Book > Send KAS); it stays editable.
    var prefillAddress: String? = nil
    var onComplete: (() -> Void)? = nil

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
    /// The completed send, driving the sent-confirmation half sheet.
    @State private var sentTransaction: SentTransaction?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var isEstimatingMax = false
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false

    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input).
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
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
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SendRecipientCard(
                        input: $addressInput,
                        lockedAddress: isCompoundMode ? fromAddress : nil,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showQRScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: selectResolution
                    )

                    KaspaAmountEntry(
                        fiatAmountState: fiatAmountState,
                        onAmountChange: { amountInput = $0 },
                        isEstimatingMax: isEstimatingMax,
                        maxEnabled: hasValidRecipient,
                        onMax: setMaxAmount
                    )
                    .padding(.top, 8)

                    if let availableBalanceSompi {
                        SendInfoPill { KaspaUnit.text("Available: %@ KAS", trimmedKas(availableBalanceSompi)) }
                    }

                    SendFeeControls(
                        feeTier: $feeTier,
                        isEditingFee: $isEditingFee,
                        customFeeText: $customFeeText,
                        isEstimatingFee: isEstimatingFee,
                        feeText: totalFeeSompi.map { "\(trimmedKas($0)) \(KaspaUnit.symbol)" },
                        onStartEditing: startEditingFee,
                        onCommit: commitCustomFee,
                        coinControlSummary: coinControlSummary(manualUtxos),
                        onCoinControl: { showCoinControl = true }
                    )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    SendActionButton(
                        title: isCompoundMode ? "Slide to Consolidate" : "Slide to Send",
                        isBusy: isSending,
                        isEnabled: canSend,
                        action: send
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            // The recipient card only shows the lookup; this screen runs it.
            .onChange(of: addressInput) { handleInputChange($0) }
            .onChange(of: feeTier) { _ in
                customExtraFeeSompi = nil
                isEditingFee = false
            }
            .navigationTitle(isCompoundMode ? "Compound UTXOs" : "Send Kaspa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: fromAddress, initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                }
            }
            // A half sheet rather than the dimmed overlay card this used to be, so every send in
            // the app finishes the same way - see `SentConfirmationSheet`.
            .sheet(item: $sentTransaction) { sent in
                SentConfirmationSheet(transaction: sent) {
                    sentTransaction = nil
                    dismiss()
                    onComplete?()
                }
                .presentationDetents([.height(sent.sheetHeight)])
                .presentationDragIndicator(.visible)
            }
            .task(id: feeEstimationKey) {
                guard hasValidRecipient, let amountSompi else {
                    normalFeeSompi = nil
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let fee = try await chatService.estimateWithdrawalFee(toAddress: effectiveAddress, amountSompi: amountSompi, manualUtxos: manualUtxos)
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = fee
                } catch {
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = nil
                }
                isEstimatingFee = false
            }
            .task {
                if isCompoundMode {
                    addressInput = fromAddress
                    isValidAddress = true
                    setMaxAmount()
                } else if let prefillAddress, addressInput.isEmpty {
                    addressInput = prefillAddress
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            // the other network's address is the same key on another chain: refused
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
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
                let maxSompi = try await chatService.estimateMaxWithdrawalAmount(toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                await MainActor.run {
                    amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = UserFacingError.message(for: error)
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
        guard let normalFeeSompi, let totalSompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
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
                let txId = try await chatService.sendWithdrawal(toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                await MainActor.run {
                    isSending = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: amountSompi,
                        // The domain when one was resolved, otherwise the address itself.
                        recipient: resolvedDomain ?? recipient
                    )
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = UserFacingError.message(for: error)
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

#Preview {
    ProfileView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
}


// MARK: - Profile Help screen

/// All the app's guides in one place, reached from Profile > Help: the first-run Welcome
/// Guide, the KNS profile setup wizard, and the 4.0 dock walkthrough (Chats-tab cycling).
/// Welcome/KNS replay through ProfileView's own covers (callbacks); the dock guide presents
/// right here.
struct ProfileHelpView: View {
    let onWelcomeGuide: () -> Void
    let onKNSSetupGuide: () -> Void


    var body: some View {
        List {
            Section {
                helpRow(
                    icon: "sparkles",
                    title: "Welcome Guide",
                    subtitle: "The full first-run tour: wallet, chats, payments and more."
                ) {
                    onWelcomeGuide()
                }
                helpRow(
                    icon: "person.text.rectangle",
                    title: ".kachat Profile Setup Guide",
                    subtitle: "Claim your .kachat name and set up your avatar, banner and bio step by step."
                ) {
                    onKNSSetupGuide()
                }
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.large)
    }

    private func helpRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.scaled(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Claim Testnet Kaspa (Profile, testnet only)

/// "Claim Testnet Kaspa", above the Chatting card on testnet. The official TN10 faucet sits
/// behind a Cloudflare check, so it can't be claimed from in the background: the button copies
/// the chatting address (`kaspatest:` form) and opens the faucet in the in-app browser, with a
/// strip saying it's copied, where you paste it, pass the
/// check and claim the most it offers. The faucet allows one claim a day, so once the address's
/// balance goes up after a visit the button locks for 24 hours (kept per address).
struct TestnetFaucetClaimButton: View {
    let address: String

    static let faucetURL = URL(string: "https://faucet-tn10.kaspanet.io")!
    private static let lockInterval: TimeInterval = 24 * 60 * 60

    @ObservedObject private var walletManager = WalletManager.shared
    @State private var showFaucet = false
    @State private var balanceBefore: UInt64?
    @State private var checkingClaim = false
    @State private var claimedAt: Date?

    private var defaultsKey: String { "kachat_tn10_faucet_claimed_\(address.lowercased())" }

    /// The chatting address in its TN10 (`kaspatest:`) form - what the faucet's address field
    /// takes. The wallet already shows it that way on testnet; this makes sure of it.
    private var tn10Address: String {
        guard let a = KaspaAddress(address: address.lowercased()), a.hrp != "kaspatest" else { return address }
        let converted = KaspaAddress(hrp: "kaspatest", type: a.type, payload: a.payload).address
        return converted.isEmpty ? address : converted
    }

    private func unlockDate(_ now: Date) -> Date? {
        guard let claimedAt else { return nil }
        let until = claimedAt.addingTimeInterval(Self.lockInterval)
        return until > now ? until : nil
    }

    private func remaining(until: Date, now: Date) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = until.timeIntervalSince(now) >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        f.calendar?.locale = AppLocalization.locale
        return f.string(from: max(60, until.timeIntervalSince(now))) ?? ""
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let until = unlockDate(context.date)
            Button {
                UIPasteboard.general.string = tn10Address
                Haptics.success()
                balanceBefore = walletManager.currentWallet?.balanceSompi
                showFaucet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: checkingClaim ? "hourglass" : (until == nil ? "drop.fill" : "checkmark.circle.fill"))
                        .font(.title3)
                        .foregroundColor(until == nil ? .accentColor : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claim Testnet Kaspa")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(until == nil ? .primary : .secondary)
                        Group {
                            if checkingClaim {
                                Text("Waiting for the faucet's payment...")
                            } else if let until {
                                Text(verbatim: String(format: AppLocalization.string("Claimed. You can claim again in %@."), remaining(until: until, now: context.date)))
                            } else {
                                Text("Copies your chatting address and opens the TN10 faucet: paste it, pass the check and claim the most it offers.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if until == nil, !checkingClaim {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(until == nil ? 0.15 : 0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(until != nil || checkingClaim)
        }
        .onAppear {
            claimedAt = UserDefaults.standard.object(forKey: defaultsKey) as? Date
        }
        .fullScreenCover(isPresented: $showFaucet, onDismiss: { Task { await checkForClaim() } }) {
            InAppBrowserScreen(
                url: Self.faucetURL,
                notice: AppLocalization.string("Your TN10 chatting address is copied. Paste it into the faucet's address field.")
            ) { showFaucet = false }
        }
    }

    /// After the faucet closes: the payment usually lands within seconds, so watch the chatting
    /// balance for up to a minute. A rise means the claim went through - lock for 24 hours.
    /// No rise (no claim, or the faucet refused) leaves the button free to try again.
    private func checkForClaim() async {
        guard let before = balanceBefore else { return }
        checkingClaim = true
        defer { checkingClaim = false }
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            if let now = try? await walletManager.refreshBalance(force: true), now > before {
                let at = Date()
                claimedAt = at
                UserDefaults.standard.set(at, forKey: defaultsKey)
                Haptics.success()
                return
            }
        }
    }
}

// MARK: - Profile Apps screen (Kaspa ecosystem quick links)

/// Bubble-style launchers for Kaspa ecosystem sites, each opening in an IN-APP browser
/// (SFSafariViewController) rather than kicking the user out to Safari.
struct ProfileAppsView: View {
    struct EcosystemApp: Identifiable {
        let name: String
        let icon: String
        let usesKaspaLogo: Bool
        let url: URL
        var id: String { name }
    }

    private let apps: [EcosystemApp] = [
        EcosystemApp(name: "Kaspa.org", icon: "", usesKaspaLogo: true, url: URL(string: "https://kaspa.org")!),
        EcosystemApp(name: "Kaspa Stream", icon: "waveform.path.ecg", usesKaspaLogo: false, url: URL(string: "https://kaspa.stream")!),
        EcosystemApp(name: "Kaspa Explorer", icon: "magnifyingglass", usesKaspaLogo: false, url: URL(string: "https://explorer.kaspa.org")!),
        EcosystemApp(name: "KasMap", icon: "map", usesKaspaLogo: false, url: URL(string: "https://kasmap.org")!),
        EcosystemApp(name: "KasShi", icon: "play.rectangle.fill", usesKaspaLogo: false, url: URL(string: "https://kasshi.io")!),
        EcosystemApp(name: "Kaspa News", icon: "newspaper", usesKaspaLogo: false, url: URL(string: "https://kaspa.news")!),
        EcosystemApp(name: "KasPlay", icon: "gamecontroller", usesKaspaLogo: false, url: URL(string: "https://kasplay.fun")!),
        EcosystemApp(name: "KasMart", icon: "cart", usesKaspaLogo: false, url: URL(string: "https://kasmart.org")!),
        EcosystemApp(name: "KasMedia", icon: "doc.text.image", usesKaspaLogo: false, url: URL(string: "https://kasmedia.com")!),
        EcosystemApp(name: "Kaspalytics", icon: "chart.bar", usesKaspaLogo: false, url: URL(string: "https://www.kaspalytics.com")!),
        EcosystemApp(name: "Kas-Smiths", icon: "hammer", usesKaspaLogo: false, url: URL(string: "https://kas-smiths.org")!),
        EcosystemApp(name: "Kaspa Core R&D", icon: "atom", usesKaspaLogo: false, url: URL(string: "https://t.me/kasparnd")!),
        // Free testnet-10 KAS for the app's testnet mode (Settings > Testnet uses TN10).
        EcosystemApp(name: "TN10 Faucet", icon: "drop.fill", usesKaspaLogo: false, url: URL(string: "https://faucet-tn10.kaspanet.io")!)
    ]

    @State private var browserURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(apps) { app in
                    Button {
                        Haptics.impact(.light)
                        browserURL = app.url
                    } label: {
                        VStack(spacing: 8) {
                            Group {
                                if app.usesKaspaLogo {
                                    Image("KaspaLogo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: app.icon)
                                        .font(.scaled(size: 28, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .frame(width: 68, height: 68)
                            .background(
                                Circle()
                                    .fill(.regularMaterial)
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                            )
                            Text(app.name)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle(AppTab.apps.ecosystemTitle)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) {
                    self.browserURL = nil
                }
            }
        }
    }
}

/// Full-screen in-app browser: the X in the top-left is the ONLY way out (full-screen cover,
/// so there's no slide-down to dismiss).
///
/// While the browser is up, the app powers down like it was backgrounded: node discovery
/// pauses, the chat poll timer stops, the KaPosts notification poller stops, and (in
/// remote-push mode) the UTXO subscription is released so notifications arrive via push -
/// exactly the closed-app path. All of it resumes when the X is tapped.
struct InAppBrowserScreen: View {
    let url: URL
    /// Optional strip under the top bar (Claim Testnet Kaspa: "your address is copied").
    var notice: String? = nil
    let onClose: () -> Void

    @State private var isLoading = true

    private func powerDownForBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.pauseDiscovery()
            ChatService.shared.stopPollingTimerOnly()
            KaPostsNotificationService.shared.stop()
            if AppSettings.load().notificationMode == .remotePush {
                ChatService.shared.pauseUtxoSubscriptionForRemotePush()
            }
        }
    }

    private func powerUpAfterBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.resumeDiscovery()
            ChatService.shared.startPolling()
            KaPostsNotificationService.shared.start()
            if AppSettings.load().notificationMode == .remotePush {
                await ChatService.shared.resumeUtxoSubscriptionForRemotePush()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Haptics.impact(.light)
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(url.host ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Color.clear
                        .frame(width: 34, height: 34)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let notice {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundColor(.accentColor)
                    Text(verbatim: notice)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.15))
            }
            Divider()
            InAppWebView(url: url, isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { powerDownForBrowsing() }
        .onDisappear { powerUpAfterBrowsing() }
    }
}

private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: InAppWebView

        init(_ parent: InAppWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

/// One .kas domain opened for profile editing - see `ProfileView.openDomainProfileEditor`.
private struct DomainProfileEditTarget: Identifiable {
    let info: KNSAddressProfileInfo
    var id: String { info.assetId ?? info.address }
}

/// "Edit KaChat Profile": the live address profile editor (`KachatLiveProfileEditor`) on both
/// networks - it writes the `kchat:1:profile:` record, a self-send that needs no registry, so it
/// saves on mainnet too; only the primary name waits for mainnet's registry.
struct KaChatProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var showSetupGuide = false

    var body: some View {
        if KachatNamesService.isEnabled {
            KachatLiveProfileEditor()
        } else {
            comingSoonEditor
        }
    }

    private var comingSoonEditor: some View {
        NavigationStack {
            Form {
                // The setup guide lives here since 5.2 - .kachat is the name KaChat sets up for
                // you; .kas profiles are edited field by field in Your Domains.
                if walletManager.showSetupGuides {
                    Section {
                        Button {
                            showSetupGuide = true
                        } label: {
                            Text("Setup Guide")
                        }
                    } footer: {
                        Text("Walk through claiming your .kachat name and setting up your avatar, banner and details step by step.")
                    }
                }

                Section {
                    Label {
                        Text(".kachat names are coming. Once you claim one, your avatar, banner, bio and links are set here - and they're what KaChat shows for you everywhere.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "at.circle")
                            .foregroundColor(.accentColor)
                    }
                }

                Section("Avatar") {
                    Label("Choose Avatar", systemImage: "photo")
                        .foregroundColor(.secondary)
                }

                Section("Banner") {
                    Label("Choose Banner", systemImage: "photo.on.rectangle")
                        .foregroundColor(.secondary)
                }

                Section("Profile") {
                    ForEach(["Bio", "X handle", "Website", "Telegram", "Discord user id", "Email", "GitHub", "Redirect URL"], id: \.self) { field in
                        Text(LocalizedStringKey(field))
                            .foregroundColor(.secondary)
                    }
                }

                Section(".kachat Name") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text("None yet")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showSetupGuide) {
                KachatSetupGuideView { showSetupGuide = false }
            }
        }
    }
}
