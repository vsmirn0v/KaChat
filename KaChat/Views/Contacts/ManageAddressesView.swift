import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Spending-chain address manager, reached from Profile > Spending Address. Mirrors Android's
/// Manage Addresses screen: a list of spending-chain addresses with live balances, a "generate
/// new slot" action, per-row set-primary (a pure pointer switch — no funds are moved) and
/// withdraw.
struct ManageAddressesView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isDiscovering = false
    @State private var isConsolidating = false
    @State private var showConsolidateConfirm = false
    @State private var showConsolidateSuccess = false
    @State private var consolidateSentTxIds: [String] = []
    @State private var switchingPrimaryIndex: Int?
    @State private var errorMessage: String?
    @State private var qrTarget: SpendingAddressEntry?
    @State private var renameTarget: SpendingAddressEntry?
    @State private var renameText = ""
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    /// Addresses that own at least one KNS domain (cached assets-by-owner lookup) - drives the
    /// "Contains domain" row tag and promotes those rows into the funded group in the sort.
    @State private var domainOwningAddresses: Set<String> = []
    /// Addresses in an ACTIVE live payment pool (Chats Payment Privacy). These rows live on
    /// the Chat Privacy tab (read-only) instead of the main Addresses list, and can't be
    /// hidden while actively offered - the user should always see which addresses are held
    /// ready for contacts to pay into. When an offer reverts (our revoke, the contact's
    /// revoke, a superseding re-offer, or funding), the address leaves this set and its row
    /// moves back to the main list as a normal address again: hideable, recyclable.
    @State private var reservedPoolAddresses: Set<String> = []
    /// Zero-balance addresses whose used/unused probe has NOT confirmed an answer - either
    /// still in flight this load, or failed (network/rate limit). Their badge shows a neutral
    /// "Checking" state instead of a possibly-wrong "Unused", and Generate refuses to recycle
    /// them without a targeted probe. Seeded with every unprobed row at the start of a load
    /// and shrunk per-row the moment each probe lands, so low rows resolve within a second
    /// or two of the screen opening instead of when the whole sweep ends.
    @State private var unknownUsedAddresses: Set<String> = []
    /// The bulk show/hide checklist (toolbar top-right).
    @State private var showVisibilityManager = false

    /// Top-of-screen tab switch, same segmented-picker treatment as the address-details
    /// screen's History/UTXOs/KNS Domains tabs. "Addresses" is the normal spending-address
    /// list; "Chat Privacy" is the read-only view of addresses actively offered to contacts
    /// as Chats Payment Privacy pool reservations.
    private enum ManageTab: String, CaseIterable {
        case addresses = "Addresses"
        case chatPrivacy = "Chat Privacy"
    }
    @State private var selectedTab: ManageTab = .addresses

    /// The current account's Chats Payment Privacy toggle, read live (same per-account key
    /// SettingsViewModel/ChatService read; recomputed whenever WalletManager republishes).
    /// While OFF this screen is just the plain Addresses list: the segmented control and the
    /// Chat Privacy tab disappear entirely. Any reservation still flagged active while OFF
    /// (a revoke that hasn't landed yet) is rendered in the main list as a normal row
    /// instead of being filtered into the hidden tab - see `visibleEntries`.
    private var chatsPrivacyOn: Bool {
        guard let wallet = walletManager.currentWallet else { return true }
        return AppSettings.chatsPrivacyEnabled(for: wallet.publicAddress)
    }

    /// Authoritative primary index, read live from WalletManager rather than the rows'
    /// snapshotted `isCurrent` flags - a payment send can rotate the primary while this
    /// screen's entries are stale, and every isCurrent-dependent decision here (the star,
    /// the sort, Set as Primary / Hide menu items) must follow the rotation immediately.
    /// WalletManager republishes `currentWallet` on rotation, so this recomputes right away.
    private var primaryIndex: Int {
        walletManager.currentSpendingAddressIndex
    }

    /// Rows for the main Addresses tab: not hidden, and not currently offered to a contact
    /// as an ACTIVE payment-pool reservation - those live on the Chat Privacy tab instead.
    /// A reverted reservation (revoke, superseding re-offer, or funding-and-revert) leaves
    /// `reservedPoolAddresses` and automatically reappears here as a normal row.
    /// With Chats Payment Privacy OFF the Chat Privacy tab doesn't exist, so nothing is
    /// filtered out here - a straggler reservation whose revoke hasn't landed yet must not
    /// become invisible on both tabs.
    private var visibleEntries: [SpendingAddressEntry] {
        entries.filter { !$0.hidden && (!chatsPrivacyOn || !reservedPoolAddresses.contains($0.address)) }
    }

    private var hiddenCount: Int {
        entries.filter { $0.hidden }.count
    }

    /// Rows for the Chat Privacy tab: every address in an ACTIVE live payment pool,
    /// regardless of hidden flag (loadEntries un-hides them anyway). Read-only.
    private var chatPrivacyEntries: [SpendingAddressEntry] {
        entries
            .filter { reservedPoolAddresses.contains($0.address) }
            .sorted { $0.index < $1.index }
    }

    /// Primary always first regardless of its own balance/index. After that: addresses that
    /// have a balance OR contain a KNS domain (keeping the pre-existing funded-first/newest-
    /// index-first relative order within that group), then fresh/unused addresses last - so a
    /// freshly-generated address (highest index, unfunded) lands immediately under the last
    /// active address rather than mixed in with them.
    private var sortedEntries: [SpendingAddressEntry] {
        let primary = visibleEntries.filter { $0.index == primaryIndex }
        let rest = visibleEntries
            .filter { $0.index != primaryIndex }
            .sorted { lhs, rhs in
                if (lhs.balanceSompi > 0) != (rhs.balanceSompi > 0) {
                    return lhs.balanceSompi > 0
                }
                return lhs.index > rhs.index
            }
        // Stable partition: domain-holding rows rank with the funded group, but relative order
        // inside each group stays exactly what the comparator above produced.
        let active = rest.filter { $0.balanceSompi > 0 || domainOwningAddresses.contains($0.address) }
        let fresh = rest.filter { $0.balanceSompi == 0 && !domainOwningAddresses.contains($0.address) }
        return primary + active + fresh
    }

    var body: some View {
        VStack(spacing: 0) {
            // The tab switch only exists while Chats Payment Privacy is ON for this account -
            // OFF means no live pools, so the screen is just the plain Addresses list.
            if chatsPrivacyOn {
                Picker("", selection: $selectedTab) {
                    ForEach(ManageTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            List {
                if selectedTab == .addresses || !chatsPrivacyOn {
                    addressesTabContent
                } else {
                    chatPrivacyTabContent
                }
            }
            .listStyle(.plain)
            .refreshable {
                await loadEntries()
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The action menu belongs to the Addresses tab only - the Chat Privacy tab is
            // purely a viewer, so Generate/Discover/Consolidate disappear entirely there.
            // With privacy OFF the screen IS the Addresses list, whatever selectedTab says.
            if selectedTab == .addresses || !chatsPrivacyOn {
                Menu {
                    Button {
                        generateNew()
                    } label: {
                        Label("Generate New Spending Address", systemImage: "plus.circle")
                    }
                    Button {
                        discoverAddresses()
                    } label: {
                        Label("Discover Addresses", systemImage: "magnifyingglass")
                    }
                    Button {
                        showConsolidateConfirm = true
                    } label: {
                        Label("Send All Kaspa To Primary Spend Address", systemImage: "arrow.up.to.line")
                    }
                } label: {
                    Group {
                        if isGenerating || isDiscovering || isConsolidating {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text("Address Actions")
                                .font(.subheadline)
                                .fontWeight(.bold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
                }
                .tint(.accentColor)
                .padding(.horizontal)
                .padding(.bottom, 16)
                .disabled(isGenerating || isDiscovering || isConsolidating)
            }
        }
        .navigationTitle("Manage Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Bulk visibility manager: compact checkmark list of EVERY address, so dozens can
            // be toggled off the main list in one sitting.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showVisibilityManager = true
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel(Text("Manage address visibility"))
            }
        }
        .sheet(isPresented: $showVisibilityManager, onDismiss: {
            // Apply the visibility edits to the rows we already have IMMEDIATELY -
            // loadEntries() re-fetches every balance and used-flag, which takes long
            // enough on big wallets that the screen looked stale after hitting Done.
            applyVisibilityChangesInstantly()
            Task { await loadEntries() }
        }) {
            SpendingAddressVisibilityView()
        }
        .task {
            // Stale tab selection from a previous visit: with privacy now OFF the Chat
            // Privacy tab is gone, so fall back to the (only) Addresses view.
            if !chatsPrivacyOn { selectedTab = .addresses }
            await loadEntries()
        }
        // Live own-address receive detected (AddressActivityNotifier) - refresh balances so
        // the screen reflects the funds without a manual pull.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
            Task { await loadEntries() }
        }
        // Always-post variant: also fires for self-send change (payment rotation,
        // consolidation) that the notification-gated event above suppresses.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            Task { await loadEntries() }
        }
        // Primary pointer rotated (post-send rotation or Set as Primary elsewhere) - the rows
        // already read the live primary index for the star and menu guards, so they update the
        // moment WalletManager republishes; this reload refreshes balances and the persisted
        // snapshot so the old primary's row is consistent (and hideable) right away.
        .onReceive(NotificationCenter.default.publisher(for: .spendingPrimaryChanged)) { _ in
            Task { await loadEntries() }
        }
        .toast(message: toastMessage)
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showConsolidateConfirm) {
            ConsolidateToPrimaryConfirmView(
                sources: entries.filter { $0.index != walletManager.currentSpendingAddressIndex && $0.balanceSompi > 0 },
                primaryAddress: walletManager.currentSpendingAddress() ?? ""
            ) { extraFeeSompi in
                consolidateToPrimary(extraFeeSompi: extraFeeSompi)
            }
            // .medium clipped the fee row's footer text on shorter screens once the fee
            // picker/editable field pushed the "From" list below the fold - always opening
            // full height avoids that ambiguity for what's a fund-affecting confirmation.
            .presentationDetents([.large])
        }
        .overlay {
            if showConsolidateSuccess {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { showConsolidateSuccess = false }
                    ConsolidateSuccessCard(
                        txIds: consolidateSentTxIds,
                        explorer: settingsViewModel.settings.kaspaExplorer
                    ) {
                        showConsolidateSuccess = false
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showConsolidateSuccess)
        .sheet(item: $qrTarget) { entry in
            SpendingAddressQRView(entry: entry)
        }
        .alert(
            "Rename Address",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let renameTarget {
                    walletManager.setSpendingAddressLabel(index: renameTarget.index, label: renameText)
                }
                renameTarget = nil
                Task { await loadEntries() }
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Give this address a label to help you recognize it.")
        }
    }

    /// The original Manage Addresses list, unchanged - minus rows actively offered to a
    /// contact as payment-pool reservations, which now live on the Chat Privacy tab.
    @ViewBuilder
    private var addressesTabContent: some View {
        chattingAddressWarningCard
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        if isLoading && entries.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 20)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if visibleEntries.isEmpty {
            emptyState
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            // Hiding moved to the bulk Address Visibility screen (toolbar checklist) -
            // the old swipe-to-hide is gone.
            ForEach(sortedEntries) { entry in
                addressRow(entry)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    /// Read-only viewer for addresses currently offered to contacts in LIVE Chats Payment
    /// Privacy pools. Rows expose only Copy Address and Show QR Code - no rename, hide,
    /// set-primary, or history navigation; the offer lifecycle (revoke/supersede/fund)
    /// manages these rows, not the user.
    @ViewBuilder
    private var chatPrivacyTabContent: some View {
        chatPrivacyDescriptionHeader
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        if isLoading && entries.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 20)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if chatPrivacyEntries.isEmpty {
            chatPrivacyEmptyState
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(chatPrivacyEntries) { entry in
                chatPrivacyRow(entry)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    /// Brief explainer above the Chat Privacy list (and its empty state) - same secondary
    /// footer-text treatment as the app's other section explainers.
    private var chatPrivacyDescriptionHeader: some View {
        Text("These are fresh addresses offered to your contacts for private payments. Each contact gets their own, so your payment history stays unlinkable. KaChat keeps at least 2 fresh addresses per chat and replaces them as they are used.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chatPrivacyEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Chat Privacy Addresses")
                .font(.headline)
            Text("When you chat with someone while Chats Payment Privacy is on, the fresh addresses offered to them appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Same card styling as the main list's rows (glass card, caption label, monospaced
    /// address), but read-only: the only menu items are Copy Address and Show QR Code,
    /// and the row doesn't navigate anywhere. Balance shows only once funds arrive, so a
    /// funded-but-still-active offer displays what came in.
    private func chatPrivacyRow(_ entry: SpendingAddressEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Address #\(entry.index)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    if let label = entry.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(entry.shortAddress)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.primary)
                if entry.balanceSompi > 0 {
                    Text("\(formatKasExact(entry.balanceSompi)) KAS")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }

            Spacer()

            Menu {
                Button {
                    UIPasteboard.general.string = entry.address
                    Haptics.success()
                    showToast("Address copied to clipboard.")
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
                Button {
                    qrTarget = entry
                } label: {
                    Label("Show QR Code", systemImage: "qrcode")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .tint(.accentColor)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    /// Matches the address rows below font-for-font (small secondary label, monospaced primary
    /// value) rather than a bold title - it used to read as a bigger, more prominent card than
    /// the rest of the list even though it's just one more address among equals here.
    private var chattingAddressWarningCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chatting Address")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            if let identity = walletManager.currentWallet?.publicAddress {
                Text(identity)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Never send Kaspa you intend to spend to this address — it's for chatting fees only.")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Spending Addresses")
                .font(.headline)
            Text("Generate one below to start sending payments from a separate address than the one you chat from.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func addressRow(_ entry: SpendingAddressEntry) -> some View {
        let isUsed = entry.everUsed || entry.balanceSompi > 0
        // Live, not the row's snapshotted isCurrent - see primaryIndex.
        let isPrimary = entry.index == primaryIndex
        // The history probe for this address failed on the last load: used-ness is unknown,
        // and claiming "Unused" could invite address reuse. Pull to refresh re-checks.
        let usedUnknown = !isUsed && unknownUsedAddresses.contains(entry.address)

        return ZStack {
            NavigationLink {
                SpendingAddressTransactionHistoryView(entry: entry)
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(entry.displayLabel)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        if isPrimary {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(entry.shortAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("\(formatKasExact(entry.balanceSompi)) KAS")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    HStack(spacing: 6) {
                        Text(isUsed ? "Used" : (usedUnknown ? "Checking" : "Unused"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(isUsed ? .orange : (usedUnknown ? .secondary : .green))
                        if domainOwningAddresses.contains(entry.address) {
                            ContainsDomainTag()
                        }
                    }
                }

                Spacer()

                if switchingPrimaryIndex == entry.index {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            renameText = entry.label ?? ""
                            renameTarget = entry
                        } label: {
                            Label("Rename Address", systemImage: "pencil")
                        }
                        Button {
                            UIPasteboard.general.string = entry.address
                            Haptics.success()
                            showToast("Address copied to clipboard.")
                        } label: {
                            Label("Copy Address", systemImage: "doc.on.doc")
                        }
                        Button {
                            qrTarget = entry
                        } label: {
                            Label("Show QR Code", systemImage: "qrcode")
                        }
                        if !isPrimary {
                            Button {
                                setPrimary(entry)
                            } label: {
                                Label("Set as Primary Address", systemImage: "star")
                            }
                        }
                        // Hide straight from the row — same effect as unchecking it in Address
                        // Visibility, without opening that sheet. Same guard as the checklist
                        // (against the LIVE primary index, so a just-rotated old primary is
                        // hideable immediately): never the primary, never a funded address,
                        // never an address offered to a contact as a payment-pool reservation.
                        // setSpendingAddressHidden re-enforces all three server-side regardless.
                        if !isPrimary && entry.balanceSompi == 0 && !reservedPoolAddresses.contains(entry.address) {
                            Button {
                                hideAddress(entry)
                            } label: {
                                Label("Hide Address", systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .bold))
                            .rotationEffect(.degrees(90))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .tint(.accentColor)
                    .disabled(switchingPrimaryIndex != nil)
                }
            }
            .padding(16)
        }
        .background(glassBackground(cornerRadius: 18))
    }

    /// Row-menu "Hide Address": flips the same per-wallet hidden flag the Address Visibility
    /// checklist edits (so it shows unchecked there), updates the row in place, and refreshes
    /// the persisted snapshot. setSpendingAddressHidden re-verifies primary/zero-balance
    /// server-side and returns false if the address can't be hidden.
    private func hideAddress(_ entry: SpendingAddressEntry) {
        Task {
            let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: true)
            guard ok else {
                if reservedPoolAddresses.contains(entry.address) {
                    showToast("This address is offered to a contact for private payments and stays visible.")
                } else {
                    showToast("This address can't be hidden.")
                }
                return
            }
            if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                var updated = entries[position]
                updated.hidden = true
                entries[position] = updated
            }
            walletManager.storeSpendingAddressListCache(entries)
            Haptics.success()
            showToast("Address hidden. Re-enable it in Address Visibility.")
        }
    }

    /// Instant sync after the Address Visibility sheet closes: stamp the stored hidden
    /// set onto the rows already loaded and add any newly revealed indices (pager-derived
    /// addresses beyond what this screen had), so the list reflects the user's edits the
    /// moment they hit Done. The full loadEntries() that follows fills in balances/used.
    private func applyVisibilityChangesInstantly() {
        let hidden = walletManager.hiddenSpendingIndexSet()
        var updated = entries
        for i in updated.indices {
            updated[i].hidden = hidden.contains(updated[i].index)
        }
        let known = Set(updated.map(\.index))
        let maxIndex = walletManager.maxSpendingAddressIndex
        if maxIndex >= 0 {
            for index in 0...maxIndex where !known.contains(index) && !hidden.contains(index) {
                guard let address = walletManager.spendingAddress(at: index) else { continue }
                updated.append(SpendingAddressEntry(
                    index: index,
                    address: address,
                    balanceSompi: 0,
                    isCurrent: index == walletManager.currentSpendingAddressIndex,
                    everUsed: false,
                    label: nil,
                    hidden: false
                ))
            }
        }
        entries = updated.sorted { $0.index < $1.index }
    }

    private func loadEntries() async {
        // Legacy repair first: reservations offered under the old born-hidden design get
        // un-hidden so outstanding pools are on this screen without re-offering. Then keep the
        // ACTIVE offered set current - it drives the "Chat privacy address" tag and the hide
        // guard; reverted reservations are plain rows here.
        walletManager.unhideOfferedReservationsIfNeeded()
        if let wallet = walletManager.currentWallet {
            reservedPoolAddresses = Set(PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: wallet.publicAddress))
        }
        // Instant paint from the persisted snapshot of the last full load — the screen shows
        // rows immediately (even with the network down) while the live refresh below replaces
        // them. Only used when we have nothing on screen yet, so a live list never regresses.
        if entries.isEmpty {
            let cached = walletManager.cachedSpendingAddressList()
            if !cached.isEmpty { entries = cached }
        }
        isLoading = entries.isEmpty
        let baseEntries = await walletManager.getSpendingAddressList()

        // Resolve everything answerable WITHOUT a network probe before the rows paint:
        // funded rows are used by definition (a balance proves history - persist that, it's
        // monotonic), and zero-balance rows take a cached answer when one exists (persistent
        // used cache, or this session's confirmed-unused memory). Only rows with no cached
        // answer go on the probe list; a failed earlier probe keeps its last known everUsed
        // (from the cached snapshot / previous load) instead of resetting to false.
        let previousUsed = Dictionary(entries.map { ($0.address, $0.everUsed) }, uniquingKeysWith: { first, _ in first })
        var toProbe: [SpendingAddressEntry] = []
        var merged = baseEntries.map { entry -> SpendingAddressEntry in
            var updated = entry
            if entry.balanceSompi > 0 {
                updated.everUsed = true
                chatService.markSpendingAddressUsed(entry.address)
            } else if let cached = chatService.cachedSpendingAddressUsedState(entry.address) {
                updated.everUsed = cached
            } else {
                updated.everUsed = previousUsed[entry.address] ?? false
                toProbe.append(entry)
            }
            return updated
        }
        merged.sort { $0.index < $1.index }
        entries = merged
        // Every not-yet-confirmed row shows "Checking" from the first frame and clears the
        // moment its OWN probe lands below - not when the whole sweep ends.
        unknownUsedAddresses = Set(toProbe.map(\.address))
        isLoading = false

        // Lowest indices first: they are the Generate-recycling candidates, so they should be
        // the first badges to resolve (within a second or two of the screen opening).
        //
        // Bounded concurrency, not fully serial and not unbounded: firing every zero-balance
        // address's request at once risked the REST host/CDN rate-limiting the burst and
        // returning a degraded response that isn't a clean empty result - but one-at-a-time
        // made load time scale linearly with how many zero-balance addresses existed. The cap
        // is 8 now that each probe is a one-integer transactions-count response instead of a
        // full resolved transaction, so even a full in-flight batch is tiny on the wire.
        toProbe.sort { $0.index < $1.index }
        let concurrencyLimit = 8
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let entry = pending.next() else { break }
                group.addTask { (entry.address, await self.chatService.spendingAddressUsedState(entry.address)) }
            }
            while let (address, used) = await group.next() {
                if let used {
                    if let position = entries.firstIndex(where: { $0.address == address }) {
                        entries[position].everUsed = used
                    }
                    unknownUsedAddresses.remove(address)
                    AppLog.log("[ManageAddresses] everUsed check address=%@ used=%@", address, used ? "true" : "false")
                }
                // A failed probe stays in unknownUsedAddresses: the badge keeps showing
                // "Checking" (never a possibly-wrong "Unused") and pull to refresh retries.
                if let entry = pending.next() {
                    group.addTask { (entry.address, await self.chatService.spendingAddressUsedState(entry.address)) }
                }
            }
        }

        // Persist the freshly-loaded snapshot so the NEXT open paints instantly from cache.
        walletManager.storeSpendingAddressListCache(entries)

        // Contains-domain tags, after the rows are already visible. refreshIfNeeded is the same
        // batched KNS lookup ContactsManager.fetchKNSDomainsForAllContacts uses: capped
        // concurrency, per-address debounce and failure cooldown, shared in-flight requests -
        // so re-opening this screen reads warm cache instead of re-firing a request burst.
        let addresses = baseEntries.map { $0.address }
        await KNSService.shared.refreshIfNeeded(for: addresses)
        var owners: Set<String> = []
        for address in addresses where KNSService.shared.domainCache[address]?.allDomains.isEmpty == false {
            owners.insert(address)
        }
        domainOwningAddresses = owners
    }

    private func generateNew() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            // A sequence, not a single answer: each press yields the lowest HIDDEN unused
            // index (un-hiding it), and extends the chain past the all-time max once no
            // hidden unused index remains - so repeat presses keep producing new rows.
            //
            // Fast path (Android parity): pick from the rows this screen already live-loaded
            // instead of re-fetching the list and re-probing history per press - recycling
            // trusts only a session-confirmed-unused row. A candidate whose probe hasn't
            // resolved yet (still "Checking") gets ONE targeted probe of just that row,
            // walking up to the next candidate when it turns out used, under a short overall
            // budget so the press never feels slow - this is what makes Generate reliably
            // yield the LOWEST unused index instead of skipping unresolved low rows. Only
            // when the budget runs out or a probe fails do we fall through to deriving past
            // the all-time max, which is provably fresh by construction and needs no network
            // at all. A background reload reconciles afterwards.
            // ACTIVE offers only - a reverted (revoked/superseded/funded-and-swept) and
            // re-hidden reservation is a legitimate recycle candidate again.
            let reserved: Set<String> = {
                guard let wallet = walletManager.currentWallet else { return [] }
                return Set(PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: wallet.publicAddress))
            }()
            let primaryIndex = walletManager.currentSpendingAddressIndex
            let candidates = entries
                .sorted { $0.index < $1.index }
                .filter { entry in
                    entry.hidden
                        && entry.index != primaryIndex
                        && entry.balanceSompi == 0
                        && !entry.everUsed
                        && !reserved.contains(entry.address)
                }
            var chosen: Int?
            let probeDeadline = Date().addingTimeInterval(2.0)
            for candidate in candidates {
                // Re-check against LIVE row state: the background sweep may have resolved
                // this row (either way) while an earlier iteration's probe was in flight.
                let live = entries.first(where: { $0.address == candidate.address }) ?? candidate
                if live.everUsed || live.balanceSompi > 0 || !live.hidden { continue }
                if !unknownUsedAddresses.contains(candidate.address) {
                    // Confirmed unused this session - the true lowest recyclable row.
                    chosen = candidate.index
                    break
                }
                // Unresolved: one targeted probe of just this row, bounded by what's left
                // of the press's overall budget.
                guard let used = await timedUsedProbe(candidate.address, deadline: probeDeadline) else {
                    break // budget spent or probe failed - the derive-past-max path is always safe
                }
                if let position = entries.firstIndex(where: { $0.address == candidate.address }) {
                    entries[position].everUsed = used
                }
                unknownUsedAddresses.remove(candidate.address)
                if !used {
                    chosen = candidate.index
                    break
                }
                // Confirmed used: keep walking to the next-lowest candidate.
            }
            let index: Int
            if let chosen {
                index = chosen
                _ = await walletManager.setSpendingAddressHidden(index: index, hidden: false)
                if let i = entries.firstIndex(where: { $0.index == index }) {
                    entries[i].hidden = false
                    // A recycled reverted reservation is now a personal address: never
                    // re-offer it to its original contact on a privacy re-enable.
                    if let wallet = walletManager.currentWallet {
                        PaymentPoolStore.shared.markReclaimed(address: entries[i].address, wallet: wallet.publicAddress)
                    }
                }
            } else {
                await walletManager.generateNextSpendingAddress()
                index = walletManager.maxSpendingAddressIndex
                _ = await walletManager.setSpendingAddressHidden(index: index, hidden: false)
                if let address = walletManager.spendingAddress(at: index) {
                    entries.append(SpendingAddressEntry(
                        index: index,
                        address: address,
                        balanceSompi: 0,
                        isCurrent: false,
                        everUsed: false,
                        label: nil,
                        hidden: false
                    ))
                    entries.sort { $0.index < $1.index }
                }
            }
            isGenerating = false
            // showToast auto-dismisses on the standard timer and replaces (never stacks or
            // extends) any toast a rapid earlier press put up. The old direct assignment
            // here never scheduled a dismissal, so the success toast lingered indefinitely.
            showToast("Spending address #\(index) is ready.")
            Task { await loadEntries() }
        }
    }

    /// One used-state probe raced against Generate's overall deadline. Returns the probe's
    /// tri-state answer, collapsed to `nil` for BOTH "probe failed" and "deadline hit" -
    /// Generate treats the two identically (don't recycle, fall back to derive-past-max).
    /// Returns immediately without a request when the budget is already gone.
    private func timedUsedProbe(_ address: String, deadline: Date) async -> Bool? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { return nil }
        let service = chatService
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await service.spendingAddressUsedState(address) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func discoverAddresses() {
        guard !isDiscovering else { return }
        isDiscovering = true
        Task {
            _ = await walletManager.discoverSpendingAddresses()
            await loadEntries()
            isDiscovering = false
        }
    }

    /// Sweeps every non-primary spending address's balance into the current primary, one at
    /// a time. Best-effort: a failure on one address doesn't block the rest. `extraFeeSompi`
    /// (chosen in the confirmation sheet) is applied to each individual sweep, same as any other
    /// send's fee customization - there's no single combined fee to show since this can be
    /// several separate transactions, one per source address.
    private func consolidateToPrimary(extraFeeSompi: UInt64 = 0) {
        guard !isConsolidating else { return }
        isConsolidating = true
        errorMessage = nil
        Task {
            guard let primaryAddress = walletManager.currentSpendingAddress() else {
                isConsolidating = false
                return
            }
            let activeIndex = walletManager.currentSpendingAddressIndex
            var sentTxIds: [String] = []
            for entry in entries where entry.index != activeIndex && entry.balanceSompi > 0 {
                if let maxSendable = try? await chatService.estimateMaxSpendingAddressAmount(index: entry.index, toAddress: primaryAddress, extraFeeSompi: extraFeeSompi),
                   maxSendable > 0,
                   let txId = try? await chatService.sendFromSpendingAddress(index: entry.index, toAddress: primaryAddress, amountSompi: maxSendable, extraFeeSompi: extraFeeSompi) {
                    sentTxIds.append(txId)
                }
            }
            await loadEntries()
            isConsolidating = false
            if !sentTxIds.isEmpty {
                consolidateSentTxIds = sentTxIds
                showConsolidateSuccess = true
            }
        }
    }

    /// Switches which spending address is primary — purely a pointer change. It does not move
    /// any funds: the old primary's balance (if any) simply stays put until spent or withdrawn
    /// on its own. From this point on, outgoing payments to contacts and KNS profile/domain
    /// fees are funded from the newly-selected address.
    private func setPrimary(_ entry: SpendingAddressEntry) {
        guard entry.index != primaryIndex, switchingPrimaryIndex == nil else { return }
        switchingPrimaryIndex = entry.index
        errorMessage = nil
        Task {
            await walletManager.setActiveSpendingAddress(entry.index)
            await loadEntries()
            switchingPrimaryIndex = nil
        }
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
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

/// Small teal-tinted capsule shown on address rows that own at least one KNS domain. Shared by
/// ManageAddressesView's spending-address list and ColdStorageDetailView's address list. Same
/// capsule treatment as the app's other inline badges (e.g. KNSDomainCard's "Primary"), tinted
/// with the accent color instead of drawn on a dark card.
struct ContainsDomainTag: View {
    var body: some View {
        Text("Contains domain")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// Confirm-before-you-sweep sheet for "Send All Kaspa To Primary Spend Address" - shows exactly
/// which addresses will be swept, where the funds are going, and a fee the user can adjust,
/// rather than firing off however-many transactions the instant the menu item is tapped.
private struct ConsolidateToPrimaryConfirmView: View {
    let sources: [SpendingAddressEntry]
    let primaryAddress: String
    let onConfirm: (UInt64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var feeEditorText = ""
    @FocusState private var feeFieldFocused: Bool

    /// Same reference-mass shortcut used by Cold Storage's fee editor - a fixed 1-input/2-output
    /// mass, good enough to show/edit a per-transaction fee estimate without a network round trip.
    private var referenceMass: UInt64 { ColdStorageSendEngine.referenceMassForFeeEditor }

    private var normalFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: KaspaFeePolicy.minimumRelayFeePerGramSompi)
    }

    /// Extra priority tip on top of the base (Normal-tier) fee - same Normal/Fast/Priority
    /// system as the chatting-address withdraw flow, applied per swept address here since a
    /// consolidation can be several separate transactions.
    private var extraFeeSompi: UInt64 {
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var effectiveFeeSompi: UInt64 {
        normalFeeSompi + extraFeeSompi
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if sources.isEmpty {
                        Text("No other addresses have a balance to consolidate.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sources) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayLabel)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(entry.shortAddress)
                                        .font(.system(.subheadline, design: .monospaced))
                                }
                                Spacer()
                                Text("\(formatKas(entry.balanceSompi)) KAS")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                } header: {
                    Text("From")
                }

                Section {
                    Text(primaryAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } header: {
                    Text("To (Primary Address)")
                }

                if !sources.isEmpty {
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
                                TextField("0.00", text: $feeEditorText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 100)
                                    .focused($feeFieldFocused)
                                    .onSubmit { commitCustomFee() }
                                Button {
                                    commitCustomFee()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button {
                                    feeEditorText = formatKas(effectiveFeeSompi)
                                    isEditingFee = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("~\(formatKas(effectiveFeeSompi)) KAS")
                                            .underline()
                                        Image(systemName: "pencil")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } footer: {
                        Text(sources.count > 1
                             ? "\(sources.count) separate transactions will be sent, one per address. Fast or Priority pays a higher fee to help them confirm sooner. Tap the fee amount to set a custom fee, applied to each."
                             : "If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                    }
                }
            }
            .navigationTitle("Consolidate to Primary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        feeFieldFocused = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm") {
                        onConfirm(extraFeeSompi)
                        dismiss()
                    }
                    .disabled(sources.isEmpty)
                }
            }
        }
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright, matching the chatting-address
    /// withdraw flow's identical behavior.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let kas = Double(feeEditorText), kas >= 0 else { return }
        let totalSompi = UInt64((kas * 100_000_000).rounded())
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Confirms a completed consolidation sweep - shown after "Send All Kaspa To Primary Spend
/// Address" finishes, listing every transaction id it actually submitted (there can be more
/// than one, one per source address swept) so the user has something concrete to check on an
/// explorer rather than just trusting the sheet silently closed. Same floating-card look as
/// WithdrawalSuccessCard (checkmark + "Sent" + teal tappable id) rather than a separate,
/// differently-styled full page, just extended to a list since this can be more than one id.
private struct ConsolidateSuccessCard: View {
    let txIds: [String]
    let explorer: KaspaExplorer
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)

            Text("Sent")
                .font(.headline)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                ForEach(txIds, id: \.self) { txId in
                    if let url = explorer.txURL(for: txId) {
                        Link(destination: url) {
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
                }
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

/// Scoped withdraw dialog for a single spending address — change stays on that same address
/// (no rotation), unlike the auto-sweep-and-rotate behavior of a regular chat payment. Widened
/// from `private` so ContactsView.swift's Profile-tab "Spending Address" dropdown can reuse it
/// for the primary spending address rather than duplicating this whole flow.
struct SpendingAddressWithdrawView: View {
    let entry: SpendingAddressEntry
    /// Pre-fills the recipient with `entry.address` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, matching Cold Storage's identical
    /// ColdSendFlowView behavior, since editing it away from `entry.address` would defeat the
    /// point of a compound send.
    var isCompoundMode: Bool = false
    /// UTXOs already loaded for `entry.address` by the parent (the list the user is looking at).
    /// Passed through the compound flow so the "Max" estimate and send don't depend on a second
    /// pooled fetch that can transiently return empty - which was surfacing as a spurious
    /// "No spendable UTXOs available" when compounding a large UTXO set.
    var preloadedUtxos: [UTXO] = []
    let onComplete: () -> Void

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
    @State private var isEstimatingMax = false
    @State private var errorMessage: String?
    @State private var successTxId: String?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?
    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as ContactsView's WithdrawKaspaView/AddContactView.
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    /// True once we have a usable recipient - either a resolved KNS domain or a directly valid
    /// Kaspa address (mirrors WithdrawKaspaView.hasValidRecipient).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false

    private var amountSompi: UInt64? {
        guard let kas = Double(amountInput), kas > 0 else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion. A
    /// manually-entered custom fee (tapped on the Network Fee row) overrides the tier
    /// multiplier until a tier is tapped again - same behavior as the chatting-address
    /// withdraw flow (ContactsView.WithdrawKaspaView).
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard let normalFeeSompi else { return nil }
        return normalFeeSompi + extraFeeSompi
    }

    private var feeEstimationKey: String {
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isCompoundMode {
                        HStack {
                            Image(systemName: "arrow.triangle.merge")
                                .foregroundColor(.accentColor)
                            Text(entry.address)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
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
                    }
                } header: {
                    Text(isCompoundMode ? "Consolidating This Address" : "Recipient Address")
                }

                Section {
                    HStack {
                        Button {
                            fiatAmountState.toggleMode(priceInCurrency: portfolioViewModel.currentPriceUsd)
                        } label: {
                            if fiatAmountState.isFiatMode {
                                Text(currencySymbol(for: portfolioViewModel.currentCurrency))
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 22, height: 22)
                            } else {
                                Image("KaspaLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .buttonStyle(.plain)

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
                    Text("Available: \(formatKas(entry.balanceSompi)) KAS")
                }

                Section {
                    Button {
                        showCoinControl = true
                    } label: {
                        HStack {
                            Text("Coin Control")
                                .foregroundColor(.primary)
                            Spacer()
                            if let manualUtxos {
                                Text("\(manualUtxos.count) UTXO\(manualUtxos.count == 1 ? "" : "s") selected")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Automatic")
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("Choose exactly which UTXOs to spend instead of selecting automatically.")
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
                                    Text("\(formatKas(totalFeeSompi)) KAS")
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
                    Text("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
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
                    let fee = try await chatService.estimateSpendingAddressWithdrawalFee(index: entry.index, toAddress: effectiveAddress, amountSompi: amountSompi, manualUtxos: manualUtxos, availableUtxos: isCompoundMode ? preloadedUtxos : [])
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
                    addressInput = entry.address
                    isValidAddress = true
                    setMaxAmount()
                }
            }
            .navigationTitle(isCompoundMode ? "Compound UTXOs" : "Send Kaspa from Address #\(entry.index)")
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
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: entry.address, initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                }
            }
            .overlay {
                if let successTxId {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture {
                                onComplete()
                                dismiss()
                            }
                        WithdrawalSuccessCard(
                            txId: successTxId,
                            explorerURL: settingsViewModel.settings.kaspaExplorer.txURL(for: successTxId)
                        ) {
                            onComplete()
                            dismiss()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: successTxId)
        }
        .interactiveDismissDisabled()
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
                if isCompoundMode {
                    // Consolidation is bounded by Kaspa's per-transaction mass cap, so estimate the
                    // max over only the UTXOs that fit ONE transaction (largest-first) and pin the
                    // send to exactly those inputs. This is why "Max" works even when the address has
                    // more UTXOs than a single tx can hold - it consolidates one batch; repeat to
                    // reduce further.
                    let (maxSompi, utxos) = try await chatService.maxConsolidatableChunk(index: entry.index, extraFeeSompi: tipSompi, availableUtxos: preloadedUtxos)
                    await MainActor.run {
                        manualUtxos = utxos
                        amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                        isEstimatingMax = false
                    }
                } else {
                    let maxSompi = try await chatService.estimateMaxSpendingAddressAmount(index: entry.index, toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                    await MainActor.run {
                        amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                        isEstimatingMax = false
                    }
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
        customFeeText = formatKas(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright, matching the chatting-address
    /// withdraw flow's identical behavior.
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
        // In compound mode, `manualUtxos` is the one-transaction chunk pinned by setMaxAmount() and
        // `recipient` is this address itself, so this self-sends exactly those inputs = one
        // consolidation transaction. In normal mode it's a regular send.
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        Task {
            do {
                let txId = try await chatService.sendFromSpendingAddress(index: entry.index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
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

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// White-background QR display for a single spending address, matching the same visual
/// treatment as ChattingAddressQRView (literal colors, not adaptive semantic colors, so text
/// stays readable regardless of system dark/light mode without affecting the nav bar).
private struct SpendingAddressQRView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        NavigationStack {
            Color.white
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 20) {
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

                        Text(entry.address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Color.black.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Button {
                            UIPasteboard.general.string = entry.address
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
                .navigationTitle("Address #\(entry.index)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
                .onAppear { generateQR() }
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

    private func generateQR() {
        let trimmed = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let uri = trimmed.hasPrefix("kaspa:") ? trimmed : "kaspa:\(trimmed)"
        guard let data = uri.data(using: .utf8) else { return }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        qrImage = UIImage(cgImage: cgImage)
    }
}

/// Reveals a single spending address's own derived private key - not the wallet's seed phrase -
/// so a specific address's spending capability can be exported/backed up without exposing the
/// rest of the wallet. Mirrors SettingsView's seed-phrase reveal flow at the same sensitivity
/// level (SecureView screenshot protection, tap-to-reveal with a 7s auto-hide timer, clipboard
/// auto-clear after 30s) rather than inventing a lighter-weight pattern for equally sensitive
/// key material. The caller gates presentation behind `DeviceAuth`/biometrics already, same as
/// the seed-phrase entry point does.
private struct SpendingAddressPrivateKeyView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.spendingPrivateKey(at: entry.index)?.hexString ?? "Unavailable"
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
            .navigationTitle(entry.displayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.string = value
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

/// Transaction history for a single spending address. Tapping a transaction opens it
/// directly on whichever block explorer is selected in Settings > Connection > Kaspa
/// Explorer, rather than showing an in-app detail screen.
private struct SpendingAddressTransactionHistoryView: View {
    let entry: SpendingAddressEntry

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private enum Tab: String, CaseIterable {
        case transactions = "History"
        case utxos = "UTXOs"
        case knsDomains = "KNS Domains"
    }

    @State private var selectedTab: Tab = .transactions
    @State private var transactions: [KaspaFullTransactionResponse] = []
    @State private var isLoading = false
    @State private var utxos: [UTXO] = []
    @State private var isLoadingUtxos = false
    @State private var knsDomains: [KNSDomain] = []
    @State private var isLoadingDomains = false
    @State private var domainsLoadFailed = false
    @State private var sendingDomain: KNSDomain?
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
    @State private var showPrivateKeySheet = false
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""

    private func outpointKey(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    private func tabLabel(_ tab: Tab) -> String {
        switch tab {
        case .transactions: return tab.rawValue
        case .utxos: return "\(tab.rawValue) (\(utxos.count))"
        case .knsDomains: return "\(tab.rawValue) (\(knsDomains.count))"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(formatKasExact(entry.balanceSompi)) KAS")
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch selectedTab {
            case .transactions:
                transactionsList
            case .utxos:
                utxosList
            case .knsDomains:
                knsDomainsList
            }
        }
        .navigationTitle(entry.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A single ToolbarItem with both icons inside an HStack (rather than two separate
            // ToolbarItems) so left-to-right order (Export, then Explorer) is guaranteed - but
            // each icon draws its own circular glass background explicitly, so they read as two
            // distinct pills with a gap between them instead of iOS's automatic toolbar-item
            // grouping merging adjacent trailing items into one shared pill shape.
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        if settingsViewModel.settings.biometricSpendingKeyEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view this address's private key") {
                                showPrivateKeySheet = true
                            }
                        } else {
                            showPrivateKeySheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.regularMaterial))
                    }
                    if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                        Link(destination: url) {
                            Image(systemName: "globe")
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.regularMaterial))
                        }
                    }
                }
            }
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
                .disabled(entry.balanceSompi == 0)
                .opacity(entry.balanceSompi == 0 ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showReceiveSheet) {
            SpendingAddressQRView(entry: entry)
        }
        .sheet(isPresented: $showSendSheet) {
            SpendingAddressWithdrawView(entry: entry) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            SpendingAddressWithdrawView(entry: entry, isCompoundMode: true, preloadedUtxos: utxos) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            SpendingAddressPrivateKeyView(entry: entry)
        }
        .sheet(item: $sendingDomain) { domain in
            // Same sheet as the Edit KNS Profile section's per-domain Send - parameterized so
            // the transfer is owned/funded/signed by THIS spending address's derived key.
            KNSDomainSendView(domain: domain, spendingAddressIndex: entry.index) { _ in
                sendingDomain = nil
                Task { await loadDomains() }
            }
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
                    WalletManager.shared.setSpendingUtxoLabel(address: entry.address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
            await loadTransactions()
            await loadUtxos()
            await loadDomains()
        }
    }

    private var transactionsList: some View {
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
                    Text("Combines this address's UTXOs to reduce the inputs a future send needs. A single transaction can only merge so many at once, so if this address has a very large number, tap Compound again after it confirms to keep reducing.")
                }
            }
            if isLoadingUtxos && utxos.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if utxos.isEmpty {
                Text("No UTXOs.")
                    .foregroundColor(.secondary)
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

    /// KNS domains owned by this specific spending address (assets-by-owner lookup). Rows reuse
    /// the same teal KNSDomainCard as the Edit KNS Profile domains list; tapping one opens the
    /// same KNSDomainSendView transfer sheet, scoped to this address's derivation.
    private var knsDomainsList: some View {
        List {
            if isLoadingDomains && knsDomains.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if domainsLoadFailed && knsDomains.isEmpty {
                Text("Could not load KNS domains. Pull to retry.")
                    .foregroundColor(.secondary)
            } else if knsDomains.isEmpty {
                Text("No KNS domains on this address.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(knsDomains, id: \.inscriptionId) { domain in
                    let transferable = isDomainTransferAllowed(domain)
                    Button {
                        sendingDomain = domain
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            KNSDomainCard(domain: domain)
                            if !transferable {
                                Text("This domain is listed and can't be sent right now.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!transferable)
                    .opacity(transferable ? 1 : 0.5)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadDomains()
        }
    }

    /// Same gate as the Edit KNS Profile domains list (KNSDomainsListView.isDomainTransferAllowed):
    /// needs an asset id and must not be listed on a marketplace.
    private func isDomainTransferAllowed(_ domain: KNSDomain) -> Bool {
        let status = domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && status != "listed"
    }

    private func loadDomains() async {
        isLoadingDomains = true
        // fetchInfo works for any address (assets-by-owner endpoint), shares in-flight requests,
        // and returns the cached value while a failure cooldown is active - nil means we have
        // nothing at all for this address, which we surface as the error state.
        if let info = await KNSService.shared.fetchInfo(for: entry.address) {
            knsDomains = info.allDomains
            domainsLoadFailed = false
        } else {
            knsDomains = []
            domainsLoadFailed = true
        }
        isLoadingDomains = false
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
                Text("\(formatKasExact(utxo.amount)) KAS")
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
        utxos = (try? await NodePoolService.shared.getUtxosByAddresses([entry.address])) ?? []
        isLoadingUtxos = false
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        let info = tx.direction(for: entry.address)
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
        // Confirmed live against api.kaspa.org that limit=500 works fine in a single call
        // (~0.7s) - cuts this from up to 4 sequential round trips down to 1.
        transactions = await chatService.fetchFullTransactionsPaginated(for: entry.address, pageSize: 200, maxTransactions: 200)
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Addresses hidden from the main Manage Addresses list (swipe-to-hide there). Never includes
/// the primary address or one with a balance — those can't be hidden in the first place.
private struct HiddenSpendingAddressesView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false

    private var hiddenEntries: [SpendingAddressEntry] {
        entries.filter { $0.hidden }.sorted { $0.index > $1.index }
    }

    var body: some View {
        List {
            if isLoading && entries.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if hiddenEntries.isEmpty {
                Text("No hidden addresses.")
                    .foregroundColor(.secondary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(hiddenEntries) { entry in
                    addressRow(entry)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button {
                                unhide(entry)
                            } label: {
                                Label("Unhide", systemImage: "eye")
                            }
                            .tint(.accentColor)
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Hidden Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadEntries()
        }
        .refreshable {
            await loadEntries()
        }
    }

    private func addressRow(_ entry: SpendingAddressEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayLabel)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(entry.shortAddress)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.primary)
            Text("\(formatKasExact(entry.balanceSompi)) KAS")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassBackground(cornerRadius: 18))
    }

    private func loadEntries() async {
        isLoading = true
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
    }

    private func unhide(_ entry: SpendingAddressEntry) {
        Task {
            _ = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: false)
            await loadEntries()
        }
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
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

// MARK: - Bulk address visibility (toolbar checklist on Manage Addresses)

/// A very compact list of EVERY revealed spending address with a toggleable checkmark per row -
/// checked = shown on the Manage Addresses list. Built for wallets with a hundred-plus revealed
/// addresses: tap through as many rows as you like in one sitting. Each row also shows whether
/// the address has ever been used on-chain (balance counts as used; swept-to-zero addresses are
/// checked against history lazily). The primary address and any address holding a balance can't
/// be hidden - the same rules WalletManager.setSpendingAddressHidden enforces server-side.
/// Addresses actively offered to contacts as payment-pool reservations don't appear here at
/// all: the checklist mirrors the main Addresses list, and those rows live on the Chat
/// Privacy tab (they can't be hidden or unhidden while the offer is live anyway).
private struct SpendingAddressVisibilityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var chatService: ChatService
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = true
    /// Addresses currently offered to contacts as Chats Payment Privacy pool reservations.
    /// They DO appear in this checklist - always checked, with the checkbox inert and the row
    /// labeled "Chat privacy address" - so the user sees the full picture, but they can't be
    /// unchecked while the offer is live. They still stay out of the MAIN Addresses list (the
    /// Chat Privacy tab owns them); this is checklist-only visibility.
    @State private var reservedAddresses: Set<String> = []
    /// Lazily-filled history results for zero-balance addresses (address -> ever used).
    @State private var usedByAddress: [String: Bool] = [:]
    /// Pager: 50 addresses per page, endless - pages past the revealed set derive future
    /// indices on the fly (checking one reveals it without flooding the main list).
    @State private var page = 0
    private let pageSize = 50
    /// The rows for the current page, by raw index order - STATE, rebuilt by `rebuildPage()`,
    /// never derived inside `body`. The old computed-property version called the public
    /// `walletManager.spendingAddress(at:)` once per beyond-revealed row during body
    /// evaluation: 50 separate Secure Enclave seed decrypts + PBKDF2 runs on the main thread
    /// per page render (and an all-nil page - i.e. a blank list - whenever the keychain read
    /// transiently failed), which is why tapping the next page appeared to load nothing.
    /// `rebuildPage()` derives the whole page through one shared change-key derivation instead.
    @State private var pageEntries: [SpendingAddressEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if pageEntries.isEmpty {
                            Text("These addresses couldn't be derived right now. Go back a page or reopen this screen to retry.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(pageEntries) { entry in
                            row(entry)
                        }
                    }
                    .listStyle(.plain)
                    // New identity per page: guarantees a fresh list AND resets the scroll
                    // position to the top on every page transition.
                    .id(page)
                }
            }
            .safeAreaInset(edge: .bottom) {
                pagerBar
            }
            .navigationTitle("Address Visibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
            .onChange(of: page) { _ in rebuildPage() }
            .onChange(of: entries) { _ in rebuildPage() }
        }
    }

    /// Recomputes the current page's rows: revealed indices come from the loaded entries;
    /// anything beyond derives its address through ONE shared change-key derivation
    /// (`spendingAddresses(inRange:)` - single seed decrypt for the whole page). Unrevealed
    /// rows render unchecked; active payment-pool reservations render checked-and-locked.
    private func rebuildPage() {
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        let start = page * pageSize
        let range = start..<(start + pageSize)
        let derived = walletManager.spendingAddresses(inRange: range)
        pageEntries = range.compactMap { index -> SpendingAddressEntry? in
            if let existing = byIndex[index] { return existing }
            guard let address = derived[index] else { return nil }
            return SpendingAddressEntry(
                index: index, address: address, balanceSompi: 0,
                isCurrent: false, everUsed: false, label: nil, hidden: true
            )
        }
    }

    /// Bottom pager: "#start - #end" with arrows; the right arrow never runs out (pages past
    /// the revealed set derive future addresses).
    private var pagerBar: some View {
        HStack {
            Button {
                page = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
            .disabled(page == 0)
            Spacer()
            Text("#\(page * pageSize) - #\(page * pageSize + pageSize - 1)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button {
                page += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func row(_ entry: SpendingAddressEntry) -> some View {
        let funded = entry.balanceSompi > 0
        // Live primary check - the pointer can rotate (post-send) while this sheet is open,
        // and the lock must follow the authoritative index, not the row's snapshotted flag.
        let isPrimary = entry.index == walletManager.currentSpendingAddressIndex
        // Active payment-pool reservations show here CHECKED and inert: always visible (the
        // offer lifecycle owns them, and they're force-unhidden anyway), never uncheckable
        // (toggle() guards them), labeled so the user knows why.
        let isReserved = reservedAddresses.contains(entry.address)
        let locked = isPrimary || funded || isReserved
        let visible = !entry.hidden || isReserved
        return HStack(spacing: 10) {
            Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(visible ? .accentColor : .secondary)
                .opacity(locked ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("#\(entry.index)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    if isPrimary {
                        Text("Primary")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.accentColor)
                    }
                    if isReserved {
                        Text("Chat privacy address")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.accentColor)
                    }
                    if let label = entry.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("\(entry.address.prefix(16))…\(entry.address.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            usedTag(entry, funded: funded)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
        .task(id: entry.address) { await ensureUsedLoaded(entry, funded: funded) }
    }

    @ViewBuilder
    private func usedTag(_ entry: SpendingAddressEntry, funded: Bool) -> some View {
        if funded {
            Text("\(Double(entry.balanceSompi) / 100_000_000.0, specifier: "%.4f") KAS")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.accentColor)
        } else if let used = usedByAddress[entry.address] {
            Text(used ? "Used" : "Unused")
                .font(.caption2.weight(.semibold))
                .foregroundColor(used ? .orange : .secondary)
        } else {
            Text("…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func load() async {
        // Same legacy repair + ACTIVE offered set Manage Addresses' loadEntries performs.
        // Live-pool rows render here checked-and-locked with the "Chat privacy address"
        // label (they still stay off the MAIN list - the Chat Privacy tab owns them);
        // reverted reservations toggle like any other row.
        walletManager.unhideOfferedReservationsIfNeeded()
        if let wallet = walletManager.currentWallet {
            reservedAddresses = Set(PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: wallet.publicAddress))
        }
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
        rebuildPage()
    }

    /// One history lookup per zero-balance address, cached for the session of this sheet.
    /// A failed probe stores nothing, so the row keeps its neutral "…" badge (never a
    /// possibly-wrong "Unused") and the next appearance of the row retries.
    private func ensureUsedLoaded(_ entry: SpendingAddressEntry, funded: Bool) async {
        guard !funded, usedByAddress[entry.address] == nil else { return }
        if let used = await chatService.spendingAddressUsedState(entry.address) {
            usedByAddress[entry.address] = used
        }
    }

    private func toggle(_ entry: SpendingAddressEntry) {
        // Locked rows (primary / funded / payment-pool reserved) don't toggle - mirrors the
        // server-side guard, against the LIVE primary index (the pointer can rotate while the
        // sheet is open).
        guard entry.index != walletManager.currentSpendingAddressIndex,
              entry.balanceSompi == 0,
              !reservedAddresses.contains(entry.address) else { return }
        Task {
            let revealedMax = entries.map(\.index).max() ?? -1
            if entry.index > revealedMax {
                // A derived future index from the endless pager: reveal exactly this one
                // (indices in between stay hidden so the main list doesn't flood).
                await walletManager.revealSpendingAddress(at: entry.index)
                entries = await walletManager.getSpendingAddressList()
            } else {
                let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: !entry.hidden)
                guard ok else { return }
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    var updated = entries[position]
                    updated.hidden.toggle()
                    entries[position] = updated
                }
            }
        }
    }
}
