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

    private var visibleEntries: [SpendingAddressEntry] {
        entries.filter { !$0.hidden }
    }

    private var hiddenCount: Int {
        entries.filter { $0.hidden }.count
    }

    /// Primary always first regardless of its own balance/index. After that: addresses that
    /// have a balance OR contain a KNS domain (keeping the pre-existing funded-first/newest-
    /// index-first relative order within that group), then fresh/unused addresses last - so a
    /// freshly-generated address (highest index, unfunded) lands immediately under the last
    /// active address rather than mixed in with them.
    private var sortedEntries: [SpendingAddressEntry] {
        let primary = visibleEntries.filter { $0.isCurrent }
        let rest = visibleEntries
            .filter { !$0.isCurrent }
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

    /// Hide is only ever offered for a non-primary, zero-balance address — the same guard is
    /// re-enforced (against the live balance, not this cached check) server-side in
    /// WalletManager.setSpendingAddressHidden.
    private func canHide(_ entry: SpendingAddressEntry) -> Bool {
        !entry.isCurrent && entry.balanceSompi == 0
    }

    private func hideAddress(_ entry: SpendingAddressEntry) {
        Task {
            let hidden = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: true)
            if hidden {
                await loadEntries()
            }
        }
    }

    var body: some View {
        List {
            chattingAddressWarningCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if hiddenCount > 0 {
                NavigationLink {
                    HiddenSpendingAddressesView()
                } label: {
                    Text("Hidden (\(hiddenCount))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

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
                ForEach(sortedEntries) { entry in
                    addressRow(entry)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            if canHide(entry) {
                                Button {
                                    hideAddress(entry)
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                                .tint(.gray)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
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
        .navigationTitle("Manage Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadEntries()
        }
        .task {
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
                        if entry.isCurrent {
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
                        Text(isUsed ? "Used" : "Unused")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(isUsed ? .orange : .green)
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
                        if !entry.isCurrent {
                            Button {
                                setPrimary(entry)
                            } label: {
                                Label("Set as Primary Address", systemImage: "star")
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

    private func loadEntries() async {
        isLoading = true
        let baseEntries = await walletManager.getSpendingAddressList()

        // Bounded concurrency, not fully serial and not unbounded: firing every zero-balance
        // address's request at once risked the REST host/CDN rate-limiting the burst and
        // returning a degraded response that isn't a clean empty result, which read as every
        // address being "used" - but one-at-a-time made load time scale linearly with how many
        // zero-balance addresses existed, which was the main thing making this screen feel slow
        // to open. A small concurrency cap keeps each in-flight batch small (same per-request
        // isolation the old comment cared about) while cutting wall-clock time roughly
        // proportional to the cap.
        let concurrencyLimit = 4
        let toCheck = baseEntries.filter { $0.balanceSompi == 0 }
        var usedByAddress: [String: Bool] = [:]

        var pending = toCheck.makeIterator()
        await withTaskGroup(of: (String, Bool).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let entry = pending.next() else { break }
                group.addTask { (entry.address, await self.chatService.hasSpendingAddressBeenUsed(entry.address)) }
            }
            while let (address, used) = await group.next() {
                usedByAddress[address] = used
                if let entry = pending.next() {
                    group.addTask { (entry.address, await self.chatService.hasSpendingAddressBeenUsed(entry.address)) }
                }
            }
        }

        let updatedEntries = baseEntries.map { entry -> SpendingAddressEntry in
            guard let used = usedByAddress[entry.address] else { return entry }
            var updated = entry
            updated.everUsed = used
            AppLog.log("[ManageAddresses] everUsed check address=%@ index=%d used=%@", entry.address, entry.index, used ? "true" : "false")
            return updated
        }
        entries = updatedEntries.sorted { $0.index < $1.index }
        isLoading = false

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
            await walletManager.generateNextSpendingAddress()
            await loadEntries()
            isGenerating = false
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
        guard !entry.isCurrent, switchingPrimaryIndex == nil else { return }
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
