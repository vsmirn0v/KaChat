import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Cold Storage — a fully separate area of the app for watching/spending funds held on an
/// air-gapped KasSigner device. Everything here is watch-only (public keys only); signing always
/// happens on the physical device via QR exchange, never inside KaChat.
struct ColdStorageListView: View {
    @ObservedObject private var manager = ColdStorageManager.shared

    @State private var showScanner = false
    @State private var showManualEntry = false
    @State private var manualKpubInput = ""
    @State private var pendingKpub: String?
    @State private var nameInput = ""
    @State private var importError: String?
    /// Account whose kpub QR is on screen.
    @State private var kpubQRTarget: ColdStorageAccount?
    /// Account whose actions half sheet is open.
    @State private var accountActionsTarget: ColdStorageAccount?
    /// Held across the actions sheet dismissing, so the QR can be presented after it.
    @State private var pendingKpubQRAccount: ColdStorageAccount?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        List {
            if manager.accounts.isEmpty {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(manager.accounts) { account in
                    ZStack {
                        NavigationLink {
                            ColdStorageDetailView(account: account)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)

                        accountRow(account)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    manualKpubInput = ""
                    showManualEntry = true
                } label: {
                    Label("Paste kpub", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showScanner = true
                } label: {
                    Label("Scan", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .navigationTitle("Cold Storage")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ConnectionStatusIndicator()
            }
            ToolbarItem(placement: .principal) {
                BalanceToolbarLabel()
            }
        }
        .toast(message: toastMessage)
        .sheet(item: $accountActionsTarget, onDismiss: {
            // Handing the QR over only once this sheet is fully gone; presenting one from
            // inside a sheet that is still dismissing drops it.
            if let pending = pendingKpubQRAccount {
                pendingKpubQRAccount = nil
                kpubQRTarget = pending
            }
        }) { account in
            ColdStorageAccountActionsSheet(
                account: account,
                onCopyKpub: {
                    UIPasteboard.general.string = account.kpubString
                    Haptics.success()
                    showToast("kpub copied to clipboard.")
                },
                onShowKpubQR: { pendingKpubQRAccount = account },
                onRename: { manager.renameAccount(account, to: $0) }
            )
        }
        .sheet(item: $kpubQRTarget) { account in
            ColdStorageKpubQRView(account: account)
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                beginImport(kpub: code)
            }
        }
        .alert(
            "Import Cold Storage Account",
            isPresented: Binding(
                get: { pendingKpub != nil },
                set: { if !$0 { pendingKpub = nil } }
            )
        ) {
            TextField("Name", text: $nameInput)
            // `.tint()` on an ancestor view doesn't reliably reach a native `.alert()`'s own
            // buttons on iOS (a known SwiftUI/UIAlertController quirk) - tinting each Button here
            // directly is what actually makes them teal instead of the system default blue.
            Button("Import") {
                completeImport()
            }
            .tint(.accentColor)
            .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingKpub = nil
            }
            .tint(.accentColor)
        } message: {
            Text("Give this account a name so you can recognize it.")
        }
        .tint(.accentColor)
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("kpub...", text: $manualKpubInput)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Extended Public Key")
                } footer: {
                    Text("Paste the kpub exported from your KasSigner device. This contains no private key material.")
                }
            }
            .navigationTitle("Enter kpub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showManualEntry = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Next") {
                        showManualEntry = false
                        beginImport(kpub: manualKpubInput)
                    }
                    .disabled(manualKpubInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Cold Storage Accounts")
                .font(.headline)
            Text("Scan or paste a kpub exported from your KasSigner device to watch its balance.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }


    private func accountRow(_ account: ColdStorageAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.label)
                    .fontWeight(.semibold)
                Text(account.kpubString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Haptics.impact(.light)
                accountActionsTarget = account
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
        .contentShape(Rectangle())
    }

    private func beginImport(kpub: String) {
        let trimmed = kpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KaspaExtendedPublicKey(kpubString: trimmed) != nil else {
            importError = ColdStorageError.invalidKpub.localizedDescription
            return
        }
        pendingKpub = trimmed
        nameInput = "Cold Storage \(manager.accounts.count + 1)"
    }

    private func completeImport() {
        guard let kpub = pendingKpub else { return }
        let result = manager.importAccount(kpubString: kpub, label: nameInput)
        pendingKpub = nil
        if case .failure(let error) = result {
            importError = error.localizedDescription
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

private func glassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

// MARK: - Detail

/// Address list for one Cold Storage account. Funded addresses sort to the top (newest index
/// first within each group), matching Manage Addresses' spending-chain sort so a freshly
/// generated (zero-balance) address lands right below the last funded one.
struct ColdStorageDetailView: View {
    let account: ColdStorageAccount

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var manager = ColdStorageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ColdStorageAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isDiscovering = false
    /// The address-actions half sheet.
    @State private var showAddressActions = false
    /// Address whose own actions half sheet is open.
    @State private var addressActionsTarget: ColdStorageAddressEntry?
    /// Live scan position while discovering, so the sheet can show progress rather than a spinner.
    @State private var discoveryProgress: ColdStorageManager.DiscoveryProgress?
    /// Result line kept on screen after a scan finishes, until the sheet is dismissed.
    @State private var discoverySummary: String?
    @State private var qrTarget: ColdStorageAddressEntry?
    @State private var sendTarget: ColdStorageAddressEntry?
    @State private var renameTarget: ColdStorageAddressEntry?
    @State private var renameText = ""
    @State private var renamingAccount = false
    @State private var renameAccountText = ""
    @State private var showDeleteConfirm = false
    @State private var showVisibilityManager = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var loadToken = UUID()
    /// Addresses that own at least one KNS domain (cached assets-by-owner lookup) - drives the
    /// "Contains domain" row tag and promotes those rows into the funded group in the sort.
    @State private var domainOwningAddresses: Set<String> = []
    /// Zero-balance addresses whose used/unused history probe FAILED on the last load - their
    /// badge shows a neutral "Checking" state instead of a possibly-wrong "Unused".
    @State private var unknownUsedAddresses: Set<String> = []

    private var currentAccount: ColdStorageAccount {
        manager.accounts.first { $0.id == account.id } ?? account
    }

    /// Addresses that have a balance OR contain a KNS domain first (keeping the pre-existing
    /// funded-first/newest-index-first relative order within that group), fresh/unused
    /// addresses last - matching Manage Addresses' spending-chain sort.
    private var visibleEntries: [ColdStorageAddressEntry] {
        let sorted = entries.filter { !$0.hidden }
            .sorted { lhs, rhs in
                if (lhs.balanceSompi > 0) != (rhs.balanceSompi > 0) {
                    return lhs.balanceSompi > 0
                }
                return lhs.index > rhs.index
            }
        // Stable partition: domain-holding rows rank with the funded group, but relative order
        // inside each group stays exactly what the comparator above produced.
        let active = sorted.filter { $0.balanceSompi > 0 || domainOwningAddresses.contains($0.address) }
        let fresh = sorted.filter { $0.balanceSompi == 0 && !domainOwningAddresses.contains($0.address) }
        return active + fresh
    }

    private var totalBalanceSompi: UInt64 {
        entries.filter { !$0.hidden }.reduce(0) { $0 + $1.balanceSompi }
    }

    var body: some View {
        List {
            accountSummary
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
                Text("No addresses discovered yet.")
                    .foregroundColor(.secondary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visibleEntries) { entry in
                    addressRow(entry)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(currentAccount.label)
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage)
        .toolbar {
            // Address Visibility used to be an unlabelled checklist glyph up here. It is one of
            // this account's address actions, so it lives with the others in the Address Actions
            // sheet, where it has room to say what it does.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .sheet(isPresented: $showVisibilityManager, onDismiss: {
            // Apply the visibility edits to the rows we already have IMMEDIATELY -
            // loadEntries() re-fetches every balance and used-flag, which takes long
            // enough that the screen looked stale after hitting Done.
            applyVisibilityChangesInstantly()
            Task { await loadEntries() }
        }) {
            ColdStorageAddressVisibilityView(account: currentAccount)
        }
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
        // Always-post variant: also fires for self-send change (withdrawal/compound change)
        // that the notification-gated event above suppresses.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            Task { await loadEntries() }
        }
        .sheet(item: $addressActionsTarget) { entry in
            addressRowActionsSheet(entry)
                .presentationDetents([.height(entry.balanceSompi == 0 ? 380 : 300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddressActions) {
            addressActionsSheet
                // Three rows now that Address Visibility lives here.
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $qrTarget) { entry in
            ColdStorageAddressQRView(entry: entry)
        }
        .sheet(item: $sendTarget) { entry in
            ColdSendFlowView(fromAddress: entry.address, availableBalanceSompi: entry.balanceSompi) {
                Task { await loadEntries() }
            }
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
                    manager.setAddressLabel(accountId: currentAccount.id, index: renameTarget.index, label: renameText)
                }
                renameTarget = nil
                Task { await loadEntries() }
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        }
        .alert("Rename Cold Storage Account", isPresented: $renamingAccount) {
            TextField("Name", text: $renameAccountText)
            Button("Save") {
                manager.renameAccount(currentAccount, to: renameAccountText)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Remove Cold Storage Account",
            isPresented: $showDeleteConfirm
        ) {
            Button("Remove", role: .destructive) {
                manager.removeAccount(currentAccount)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes it from KaChat's watch list. It has no effect on the KasSigner device or any funds it holds.")
        }
    }

    /// Plain labeled text instead of each stacking in its own glass card — this is summary info
    /// about the account (not a tappable row), so a card treatment just added visual noise
    /// without meaning "you can tap this."
    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currentAccount.label)
                        .fontWeight(.semibold)
                }
                Spacer()
                Button {
                    renameAccountText = currentAccount.label
                    renamingAccount = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("kpub")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(currentAccount.kpubString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                Button {
                    UIPasteboard.general.string = currentAccount.kpubString
                    Haptics.success()
                    showToast("kpub copied to clipboard.")
                } label: {
                    Label("Copy kpub", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(formatKasExact(totalBalanceSompi)) KAS")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            // Directly under the balance rather than pinned to the bottom of the screen: the
            // actions are about this account, so they belong with the account, and a floating
            // bar covered the last address row on a short list.
            Button {
                Haptics.impact(.light)
                showAddressActions = true
            } label: {
                Group {
                    if isGenerating || isDiscovering {
                        ProgressView().tint(.black)
                    } else {
                        Text("Address Actions")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(.black)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(isGenerating || isDiscovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The half sheet behind one address row's ellipsis, replacing the menu that was there.
    private func addressRowActionsSheet(_ entry: ColdStorageAddressEntry) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(entry.displayLabel)
                    .font(.headline)
                Text(entry.shortAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetRow(
                title: "Rename Address",
                subtitle: "Gives this address a label of your own.",
                systemImage: "pencil"
            ) {
                addressActionsTarget = nil
                DispatchQueue.main.async {
                    renameText = entry.label ?? ""
                    renameTarget = entry
                }
            }
            ActionSheetRow(
                title: "Copy Address",
                subtitle: "Puts the full address on the clipboard.",
                systemImage: "doc.on.doc"
            ) {
                UIPasteboard.general.string = entry.address
                Haptics.success()
                addressActionsTarget = nil
                showToast(entry.address.addressCopiedToastText)
            }
            ActionSheetRow(
                title: "Show QR Code",
                subtitle: "Full screen, for scanning with another device.",
                systemImage: "qrcode"
            ) {
                addressActionsTarget = nil
                DispatchQueue.main.async { qrTarget = entry }
            }
            // Hide straight from the row - same effect as unchecking it in Address Visibility,
            // without opening that screen. Same guard as the checklist: never a funded address
            // (cold storage has no primary-address concept).
            if entry.balanceSompi == 0 {
                ActionSheetRow(
                    title: "Hide Address",
                    subtitle: "Removes it from this list. Re-enable it in Address Visibility.",
                    systemImage: "eye.slash",
                    tint: .orange
                ) {
                    addressActionsTarget = nil
                    hideAddress(entry)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The half sheet behind "Address Actions".
    ///
    /// Discovery reports its position as it walks, and that lands HERE rather than dismissing:
    /// a scan is one network call per address until the gap limit is reached, easily half a
    /// minute, and the sheet closing on an unmoving spinner said nothing about whether it was
    /// working. The sheet stays put, counts up, and finishes with what it found.
    private var addressActionsSheet: some View {
        VStack(spacing: 0) {
            Text("Address Actions")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            if isDiscovering, let progress = discoveryProgress {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking address #\(progress.checkingIndex)")
                        .font(.subheadline.weight(.semibold))
                    Text(progress.foundCount == 0
                         ? "No used addresses yet"
                         : "\(progress.foundCount) found so far")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Scanning stops after 20 unused addresses in a row.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 12) {
                    ActionSheetRow(
                        title: "Generate More Addresses",
                        subtitle: "Reveals the next unused address in this account.",
                        systemImage: "plus.circle",
                        isBusy: isGenerating,
                        isDisabled: isDiscovering
                    ) {
                        generateMore()
                        showAddressActions = false
                    }
                    ActionSheetRow(
                        title: "Discover Addresses",
                        subtitle: "Finds addresses holding a balance or a KNS domain.",
                        systemImage: "magnifyingglass",
                        isDisabled: isDiscovering
                    ) {
                        discoverAddresses()
                    }
                    ActionSheetRow(
                        title: "Address Visibility",
                        subtitle: "Check off every address you want on the list, in one sitting.",
                        systemImage: "checklist",
                        isDisabled: isDiscovering
                    ) {
                        showAddressActions = false
                        // One runloop turn: presenting a sheet from inside one that is still
                        // dismissing drops it.
                        DispatchQueue.main.async { showVisibilityManager = true }
                    }
                    if let discoverySummary {
                        Text(discoverySummary)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Dismissing mid-scan would abandon the only progress readout, and the work keeps running
        // either way - so the sheet holds until it is done.
        .interactiveDismissDisabled(isDiscovering)
        .onDisappear { discoverySummary = nil }
    }


    private func addressRow(_ entry: ColdStorageAddressEntry) -> some View {
        let isUsed = entry.everUsed || entry.balanceSompi > 0
        // The history probe for this address failed on the last load: used-ness is unknown,
        // and claiming "Unused" could invite address reuse. Pull to refresh re-checks.
        let usedUnknown = !isUsed && unknownUsedAddresses.contains(entry.address)

        return ZStack {
            NavigationLink {
                ColdStorageAddressTransactionHistoryView(entry: entry)
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.displayLabel)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
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

                Button {
                    Haptics.impact(.light)
                    addressActionsTarget = entry
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(glassBackground(cornerRadius: 18))
    }

    /// Row-menu "Hide Address": flips the same per-account hidden flag the Address Visibility
    /// checklist edits (so it shows unchecked there) and updates the row in place.
    /// setAddressHidden re-verifies the live balance server-side and returns false if the
    /// address can't be hidden. Mirrors Manage Addresses' hideAddress.
    private func hideAddress(_ entry: ColdStorageAddressEntry) {
        Task {
            let ok = await manager.setAddressHidden(account: currentAccount, index: entry.index, hidden: true)
            guard ok else {
                showToast("This address can't be hidden.")
                return
            }
            if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                var updated = entries[position]
                updated.hidden = true
                entries[position] = updated
            }
            Haptics.success()
            showToast("Address hidden. Re-enable it in Address Visibility.")
        }
    }

    private func loadEntries() async {
        isLoading = true
        let token = UUID()
        loadToken = token

        // getAddressList's balance fetch is now a single batched gRPC call (see
        // ColdStorageManager), so addresses + balances are ready fast — show them immediately
        // instead of also waiting on the slower per-address "used" REST scan below, which was
        // making the whole list sit behind a spinner until every address (even the empty ones
        // discovery just found) had been checked one at a time.
        let baseEntries = await manager.getAddressList(for: currentAccount)
        guard loadToken == token else { return }
        entries = baseEntries.sorted { $0.index < $1.index }
        isLoading = false

        // Backfills the "Used"/"Unused" badge for zero-balance addresses in the background.
        // Sequential, not concurrent — same rate-limit reasoning as Manage Addresses'
        // spending-chain "used" check: a burst of simultaneous REST requests risked the host
        // rate-limiting and returning a degraded response that reads as "unused" when it isn't.
        // Guarded by loadToken so a stale backfill from an earlier call (e.g. before a pull-to-
        // refresh or Generate More triggers a fresh loadEntries()) can't clobber newer entries.
        //
        // Collected into `updates` and applied to `entries` in a single commit at the end rather
        // than once per address: mutating the published array on every single result was
        // re-rendering that row mid-backfill, which — if its "..." menu happened to be open at
        // that moment — visibly flickered/dismissed the open menu.
        // Tri-state per address: true/false = confirmed by a successful probe, nil = the probe
        // failed (network/rate-limit) - those rows keep their previous badge state and show a
        // neutral "Checking" instead of a possibly-wrong "Unused".
        var updates: [String: Bool] = [:]
        var failedProbes: Set<String> = []
        for entry in baseEntries where entry.balanceSompi == 0 {
            let used = await ChatService.shared.spendingAddressUsedState(entry.address)
            guard loadToken == token else { return }
            if let used {
                updates[entry.address] = used
            } else {
                failedProbes.insert(entry.address)
            }
        }
        guard loadToken == token else { return }
        if !updates.isEmpty {
            for idx in entries.indices {
                if let used = updates[entries[idx].address] {
                    entries[idx].everUsed = used
                }
            }
        }
        unknownUsedAddresses = failedProbes.filter { address in
            !(entries.first(where: { $0.address == address })?.everUsed ?? false)
        }

        // Contains-domain tags, after the rows are already visible. refreshIfNeeded is the same
        // batched KNS lookup ContactsManager.fetchKNSDomainsForAllContacts uses: capped
        // concurrency, per-address debounce and failure cooldown, shared in-flight requests -
        // so re-opening this screen reads warm cache instead of re-firing a request burst.
        let addresses = baseEntries.map { $0.address }
        await KNSService.shared.refreshIfNeeded(for: addresses)
        guard loadToken == token else { return }
        var owners: Set<String> = []
        for address in addresses where KNSService.shared.domainCache[address]?.allDomains.isEmpty == false {
            owners.insert(address)
        }
        domainOwningAddresses = owners
    }

    /// Stamps the fresh hidden set onto the rows already loaded and adds any newly revealed
    /// indices (pager-derived addresses beyond what this screen had), so the list reflects
    /// the user's edits the moment they hit Done. The full loadEntries() that follows fills
    /// in balances/used. Mirrors Manage Addresses' applyVisibilityChangesInstantly.
    private func applyVisibilityChangesInstantly() {
        let hidden = manager.hiddenIndexSet(accountId: currentAccount.id)
        var updated = entries
        for i in updated.indices {
            updated[i].hidden = hidden.contains(updated[i].index)
        }
        let known = Set(updated.map(\.index))
        let maxIndex = currentAccount.maxAddressIndex
        if maxIndex >= 0 {
            for index in 0...maxIndex where !known.contains(index) && !hidden.contains(index) {
                guard let address = manager.address(for: currentAccount, at: index) else { continue }
                updated.append(ColdStorageAddressEntry(
                    index: index,
                    address: address,
                    balanceSompi: 0,
                    hidden: false
                ))
            }
        }
        entries = updated.sorted { $0.index < $1.index }
    }

    private func generateMore() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            let index = await manager.lowestUnusedAddress(for: currentAccount)
            await loadEntries()
            isGenerating = false
            showToast("Address #\(index) is ready.")
        }
    }

    private func discoverAddresses() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoverySummary = nil
        discoveryProgress = ColdStorageManager.DiscoveryProgress(checkingIndex: 0, foundCount: 0)
        Task {
            let discovered = await manager.discoverAddresses(for: currentAccount) { progress in
                discoveryProgress = progress
            }
            await loadEntries()
            isDiscovering = false
            discoveryProgress = nil
            // The count is addresses that hold a balance or a KNS domain - say so, rather than
            // "used", which is what the old high-water-mark number implied and was not.
            discoverySummary = discovered == 0
                ? "No addresses with a balance or domain found."
                : "Found \(discovered) address\(discovered == 1 ? "" : "es") with a balance or domain."
        }
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
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

/// White-background QR display for a single Cold Storage address, matching the same visual
/// treatment as ManageAddressesView's SpendingAddressQRView.
private struct ColdStorageAddressQRView: View {
    let entry: ColdStorageAddressEntry
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

                        Text("Tap anywhere to copy")
                            .font(.footnote)
                            .foregroundColor(Color.black.opacity(0.4))

                        Spacer()
                        Spacer()
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { copyAddress() }
                .navigationTitle(entry.displayLabel)
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

    private func copyAddress() {
        UIPasteboard.general.string = entry.address
        Haptics.success()
        showToast(entry.address.addressCopiedToastText)
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

/// The full "send" round trip for one Cold Storage address: enter recipient/amount, build an
/// unsigned transaction, display it as a KSPT QR (animated if it needs multiple frames) for the
/// KasSigner device to scan, scan the signed response back, verify it matches what was sent for
/// signing, and broadcast. The engine (ColdStorageSendEngine) never sees a private key — signing
/// happens entirely on the physical device.
private struct ColdSendFlowView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64
    /// Pre-fills the recipient with `fromAddress` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point — merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, since editing it away from `fromAddress`
    /// would defeat the point of a compound send.
    var isCompoundMode: Bool = false
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    private enum Step {
        case form
        case building
        case showingQR(ColdStorageSendEngine.UnsignedColdTx, [Data])
        case scanning(ColdStorageSendEngine.UnsignedColdTx)
        case broadcasting
        case success(String)
        case failed(String)
    }

    @State private var step: Step = .form
    @State private var toAddress = ""
    @State private var isValidAddress = false
    @State private var amountText = ""
    @State private var isEstimatingMax = false
    @State private var showRecipientScanner = false

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsError: String?
    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as ContactsView's WithdrawKaspaView/AddContactView.
    private var effectiveAddress: String {
        resolvedAddress ?? toAddress
    }

    /// True once we have a usable recipient - either a resolved KNS domain or a directly valid
    /// Kaspa address (mirrors WithdrawKaspaView.hasValidRecipient).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var feeEditorText = ""
    /// Fetched once when the screen appears and reused everywhere the fee needs computing (the
    /// form preview, the QR screen, and the actual build/broadcast) — rather than letting each of
    /// those independently call `fetchQuotedFeeRateSompiPerGram()` and each potentially get a
    /// different live quote, which was exactly why the fee shown before Build didn't match what
    /// the real transaction ended up costing.
    @State private var liveFeeRateSompiPerGram: UInt64?
    /// Coin control — nil means automatic (greedy, largest-first) selection; non-nil fixes the
    /// exact input set the user picked instead.
    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false
    /// Compound mode only: true when this address holds more UTXOs than one KasSigner transaction
    /// can merge at once (`KsptCodec.maxInputs`), so the user must run Compound again after this
    /// round. Drives the "repeat to finish" note.
    @State private var compoundHasMoreRounds = false
    /// Debounced live preview of what automatic selection would pick for the current amount/fee
    /// — see `schedulePreview()`. Non-nil only while it's still fresh for the current amount/fee;
    /// cleared immediately on any change so a stale preview never gets shown or built with.
    @State private var previewSelection: ColdStorageSendEngine.AutomaticSelectionPreview?
    @State private var previewTask: Task<Void, Never>?

    private enum FormField: Hashable {
        case recipient, amount, fee
    }
    @FocusState private var focusedField: FormField?

    private var amountSompi: UInt64? {
        guard let kas = Double(amountText), kas > 0 else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    private var canBuild: Bool {
        hasValidRecipient && amountSompi != nil
    }

    /// Reference-mass fee shown/edited here, matching Android's ColdSendFlow: a fixed
    /// 1-input/2-standard-output mass when the input count isn't known yet (automatic selection,
    /// not resolved until build time) — good enough to reason about "pay more to confirm faster"
    /// without an extra network round trip just to populate this label. When coin control has
    /// fixed a UTXO set, though, the real count IS already known, so this uses that exact input
    /// count instead of guessing — otherwise the preview shown here could understate the real fee
    /// for a multi-UTXO selection, which then only became visible after tapping Build.
    private var referenceMass: UInt64 {
        guard let manualUtxos, !manualUtxos.isEmpty else {
            return ColdStorageSendEngine.referenceMassForFeeEditor
        }
        return ColdStorageSendEngine.calculateMass(numInputs: manualUtxos.count, outputScriptLens: [34, 34], payloadSize: 0)
    }

    /// Same live-or-minimum rate `ColdStorageSendEngine`'s own default falls back to — using it
    /// here too (instead of always assuming the bare protocol minimum) means the "Normal" preview
    /// matches what a nil-override build would actually charge whenever the network's live quote
    /// is currently above the minimum.
    private var baseFeeRateSompiPerGram: UInt64 {
        liveFeeRateSompiPerGram ?? KaspaFeePolicy.minimumRelayFeePerGramSompi
    }

    private var defaultFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: baseFeeRateSompiPerGram)
    }

    /// Normal/Fast/Priority multiplier system, same inline (no separate screen) pattern as the
    /// chatting-address withdraw flow and Manage Addresses' consolidate flow — see
    /// `WithdrawFeeTier` and `ContactsView`'s withdraw sheet.
    private var extraFeeSompi: UInt64 {
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return defaultFeeSompi * (feeTier.multiplier - 1)
    }

    /// The live preview (when fresh and automatic selection is in play — coin control already
    /// knows its exact count another way) takes priority over the reference-mass guess, since it
    /// reflects the real number of inputs this amount+fee will actually need.
    private var effectiveFeeSompi: UInt64 {
        if manualUtxos == nil, let previewSelection {
            return previewSelection.feeSompi
        }
        return defaultFeeSompi + extraFeeSompi
    }

    /// Converts the tier/custom-fee total back into the sompi-per-mass-gram rate
    /// `ColdStorageSendEngine` actually builds with. Always an explicit value now (never nil, even
    /// for plain Normal) — passing nil let the engine do its own separate live-quote fetch at
    /// build time, which could return a slightly different number than whatever this screen's own
    /// fetch showed moments earlier, and that drift was exactly why the fee after Build didn't
    /// match the one shown beforehand.
    private var feeRateOverride: UInt64? {
        guard feeTier != .normal || customExtraFeeSompi != nil else { return baseFeeRateSompiPerGram }
        return UInt64((Double(effectiveFeeSompi) / Double(referenceMass)).rounded(.up))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .form, .building:
                    formView
                case .showingQR(let unsignedTx, let frames):
                    qrView(unsignedTx: unsignedTx, frames: frames)
                case .scanning:
                    Color.clear // MultiFrameQRScannerView is presented as its own sheet below
                case .broadcasting:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Broadcasting...")
                            .foregroundColor(.secondary)
                    }
                case .success(let txId):
                    successView(txId: txId)
                case .failed(let message):
                    failedView(message: message)
                }
            }
            .navigationTitle(isCompoundMode ? "Compound UTXOs" : "Send from Cold Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                liveFeeRateSompiPerGram = await ColdStorageSendEngine.fetchQuotedFeeRateSompiPerGram()
                if isCompoundMode {
                    toAddress = fromAddress
                    isValidAddress = true
                    await setupCompoundInputs()
                }
            }
            .sheet(isPresented: $showRecipientScanner) {
                QRScannerView { code in
                    handleScannedRecipient(code)
                }
            }
            .sheet(isPresented: isScanningSignedResponse) {
                if case .scanning(let unsignedTx) = step {
                    MultiFrameQRScannerView(isComplete: { KsptCodec.looksLikeKspt($0) }) { data in
                        handleScannedSignedResponse(data, unsignedTx: unsignedTx)
                    }
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: fromAddress, initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                    schedulePreview()
                }
            }
        }
    }

    private var isScanningSignedResponse: Binding<Bool> {
        Binding(
            get: { if case .scanning = step { return true } else { return false } },
            set: { if !$0, case .scanning = step { step = .form } }
        )
    }

    private var formView: some View {
        Form {
            Section {
                HStack {
                    Text("From")
                    Spacer()
                    Text(fromAddress.prefix(14) + "..." + fromAddress.suffix(6))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Available")
                    Spacer()
                    Text("\(formatKas(availableBalanceSompi)) KAS")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                if isCompoundMode {
                    HStack {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundColor(.accentColor)
                        Text(fromAddress)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    TextField("kaspa:qr... or name.kas", text: $toAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .recipient)
                        .onChange(of: toAddress) { handleInputChange($0) }

                    if !toAddress.isEmpty {
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
                                toAddress = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                handleInputChange(toAddress)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Button {
                            showRecipientScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(isCompoundMode ? "Consolidating This Address" : "Recipient Address")
            } footer: {
                if isCompoundMode {
                    if compoundHasMoreRounds {
                        Text("This address has more than \(KsptCodec.maxInputs) UTXOs. KasSigner can sign at most \(KsptCodec.maxInputs) inputs per transaction, so this merges the largest \(KsptCodec.maxInputs) into one. Run Compound again afterward to keep combining the rest.")
                    } else {
                        Text("Merges all of this address's UTXOs into a single one, so future sends need fewer inputs.")
                    }
                }
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
                            set: { amountText = fiatAmountState.onDisplayTextChange($0, priceInCurrency: portfolioViewModel.currentPriceUsd) }
                        )
                    )
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                    if let conversionLabel = fiatAmountState.conversionLabelText(
                        priceInCurrency: portfolioViewModel.currentPriceUsd,
                        currency: portfolioViewModel.currentCurrency
                    ) {
                        Text(conversionLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            }

            // Compound auto-manages its own input set (largest <=8, KasSigner's per-tx limit), so
            // manual coin control is hidden there — it only applies to a normal send.
            if !isCompoundMode {
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
                        TextField("0.00", text: $feeEditorText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            .focused($focusedField, equals: .fee)
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
                            focusedField = .fee
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
                Text("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
            }

            if case .failed(let message) = step {
                Section {
                    Text(message)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                let isBuilding: Bool = { if case .building = step { return true } else { return false } }()
                Button {
                    buildTransaction()
                } label: {
                    HStack {
                        Spacer()
                        if isBuilding {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text("Build Unsigned Transaction")
                                .font(.subheadline.weight(.bold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .foregroundColor(canBuild ? .black : .secondary)
                }
                .listRowBackground((canBuild && !isBuilding) ? Color.accentColor : Color.secondary.opacity(0.2))
                .disabled(!canBuild || isBuilding)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: amountText) { _ in schedulePreview() }
        .onChange(of: feeTier) { _ in schedulePreview() }
        .onChange(of: customExtraFeeSompi) { _ in schedulePreview() }
        .onChange(of: liveFeeRateSompiPerGram) { _ in schedulePreview() }
    }

    /// Commits the manually-typed total fee. Values below the tier-computed baseline are clamped
    /// up to zero extra rather than rejected outright, matching the chatting-address withdraw
    /// flow's identical `commitCustomFee()`.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let kas = Double(feeEditorText), kas >= 0 else { return }
        let totalSompi = UInt64((kas * 100_000_000).rounded())
        customExtraFeeSompi = totalSompi > defaultFeeSompi ? totalSompi - defaultFeeSompi : 0
    }

    /// Literal white background regardless of system dark/light mode — matching this app's
    /// established convention for any screen showing a QR meant to be read by another device's
    /// camera (see ChattingAddressQRView/ColdStorageAddressQRView), and a real, plausible fix
    /// for a scan a KasSigner device failed to read: a dark surrounding background gives a
    /// phone camera photographing this screen far less contrast/exposure headroom around the
    /// code than a bright white one does.
    private func qrView(unsignedTx: ColdStorageSendEngine.UnsignedColdTx, frames: [Data]) -> some View {
        Color.white
            .ignoresSafeArea()
            .overlay(
                ScrollView {
                    VStack(spacing: 20) {
                        // From/Available/Network Fee, matching Android's ColdSendFlow: still
                        // visible on the QR step, not just the entry form.
                        VStack(spacing: 8) {
                            HStack {
                                Text("From")
                                Spacer()
                                Text(fromAddress.prefix(14) + "..." + fromAddress.suffix(6))
                                    .font(.system(.caption, design: .monospaced))
                            }
                            HStack {
                                Text("Available")
                                Spacer()
                                Text("\(formatKas(availableBalanceSompi)) KAS")
                            }
                            HStack {
                                Text("Network Fee")
                                Spacer()
                                Text("\(formatKas(unsignedTx.feeSompi)) KAS")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(Color.black.opacity(0.6))
                        .padding(.horizontal)

                        Text("Scan this on your KasSigner device")
                            .font(.subheadline)
                            .foregroundColor(Color.black.opacity(0.6))
                        AnimatedQRDisplayView(frames: frames, displaySize: 280)
                        Button {
                            step = .scanning(unsignedTx)
                        } label: {
                            Text("Scan Signed Transaction")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .foregroundColor(.black)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 24)
                }
            )
    }

    private func successView(txId: String) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("From")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(fromAddress)
                    .font(.system(.subheadline, design: .monospaced))
                Text("Available: \(formatKas(availableBalanceSompi)) KAS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(glassBackground(cornerRadius: 12))

            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Sent")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("To")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(toAddress)
                    .font(.system(.subheadline, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(glassBackground(cornerRadius: 12))

            Button {
                if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                    UIApplication.shared.open(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Transaction ID · tap to view in \(settingsViewModel.settings.kaspaExplorer.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    Text(txId)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(glassBackground(cornerRadius: 12))

            Spacer(minLength: 0)

            Button {
                onDone()
                dismiss()
            } label: {
                Text("Done")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.red)
            Text("Something Went Wrong")
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                step = .form
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleScannedRecipient(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        toAddress = address
        handleInputChange(address)
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
            isValidAddress = KaspaAddress.isValid(trimmed)
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

            guard toAddress.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  toAddress.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
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

    /// Debounced (400ms) live preview of what automatic selection would pick for the current
    /// amount + fee rate — cancels and restarts on every relevant change so a burst of typing
    /// doesn't fire a network call per keystroke, and clears the stale preview immediately (rather
    /// than leaving the last one showing) so the fee display never claims to be exact when it
    /// isn't anymore. No-ops entirely once coin control is active — that already knows its exact
    /// count without needing a preview fetch.
    private func schedulePreview() {
        previewTask?.cancel()
        previewSelection = nil
        guard manualUtxos == nil, let amountSompi else { return }
        let rate = feeRateOverride ?? baseFeeRateSompiPerGram
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let preview = await ColdStorageSendEngine.shared.previewAutomaticSelection(
                fromAddress: fromAddress,
                amountSompi: amountSompi,
                feeRateSompiPerGram: rate
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewSelection = preview
            }
        }
    }

    /// Compound mode: fix the input set to the largest <=8 UTXOs — the most one KasSigner-signable
    /// transaction can hold — then Max the amount for exactly that set. Without this cap, Max spans
    /// every UTXO at the address and the build fails with `tooManyInputs` the moment it holds more
    /// than 8. `compoundHasMoreRounds` records whether another round is needed afterward.
    private func setupCompoundInputs() async {
        do {
            let (utxos, hasMore) = try await ColdStorageSendEngine.shared.compoundInputs(fromAddress: fromAddress)
            manualUtxos = utxos
            compoundHasMoreRounds = hasMore
            setMaxAmount()
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        isEstimatingMax = true
        let overrideRate = feeRateOverride
        let utxos = manualUtxos
        Task {
            do {
                let maxSompi = try await ColdStorageSendEngine.shared.estimateMaxAmount(fromAddress: fromAddress, feeRateOverride: overrideRate, manualUtxos: utxos)
                await MainActor.run {
                    amountText = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    isEstimatingMax = false
                }
            }
        }
    }

    private func buildTransaction() {
        guard let amountSompi else { return }
        step = .building
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideRate = feeRateOverride
        // Real coin control (explicit user selection) wins if set; otherwise, if a fresh
        // automatic-selection preview is available, pass its exact UTXO set through as the
        // build's `manualUtxos` too — guaranteeing the fee just shown on this screen and the fee
        // the real build produces are the same number, not just close. Re-resolved against a
        // fresh fetch inside buildUnsignedTransaction either way, so this is never stale-unsafe.
        let utxos = manualUtxos ?? previewSelection?.utxos
        Task {
            do {
                let unsignedTx = try await ColdStorageSendEngine.shared.buildUnsignedTransaction(
                    fromAddress: fromAddress,
                    toAddress: recipient,
                    amountSompi: amountSompi,
                    feeRateOverride: overrideRate,
                    manualUtxos: utxos
                )
                let kspt = try ColdStorageSendEngine.shared.toKspt(unsignedTx)
                let frames = try QrFrameChunker.chunk(kspt)
                await MainActor.run {
                    step = .showingQR(unsignedTx, frames)
                }
            } catch {
                await MainActor.run {
                    step = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handleScannedSignedResponse(_ data: Data, unsignedTx: ColdStorageSendEngine.UnsignedColdTx) {
        step = .broadcasting
        Task {
            do {
                let decoded = try KsptCodec.decode(data)
                let txId = try await ColdStorageSendEngine.shared.broadcastSigned(unsignedTx: unsignedTx, decoded: decoded)
                await MainActor.run {
                    step = .success(txId)
                }
            } catch {
                await MainActor.run {
                    step = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }
}

/// Coin control — lets the user fix the exact UTXO set a send spends from instead of the
/// automatic largest-first selector. Reachable from a send form's "Coin Control" row - shared by
/// `ColdSendFlowView` and `SpendingAddressWithdrawView` (not Cold-Storage-specific: it fetches
/// via the generic `NodePoolService.shared.getUtxosByAddresses`, keyed only by `fromAddress`).
/// Passes the selection back as a plain `[UTXO]?` (nil = automatic) rather than owning any state
/// itself, since the actual spendable set needs re-resolving against a fresh fetch at build time
/// anyway (see `ColdStorageSendEngine.buildUnsignedTransaction`'s `manualUtxos` handling).
struct CoinControlView: View {
    let fromAddress: String
    let initialSelection: [UTXO]?
    let onDone: ([UTXO]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var utxos: [UTXO] = []
    @State private var selectedKeys: Set<String> = []
    @State private var isLoading = false
    @State private var utxoLabels: [String: String] = [:]

    private func key(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    private var selectedTotalSompi: UInt64 {
        utxos.filter { selectedKeys.contains(key($0)) }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && utxos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if utxos.isEmpty {
                    Text("No UTXOs found at this address.")
                        .foregroundColor(.secondary)
                } else {
                    Section {
                        ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                            let k = key(utxo)
                            let isSelected = selectedKeys.contains(k)
                            Button {
                                if isSelected {
                                    selectedKeys.remove(k)
                                } else {
                                    selectedKeys.insert(k)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let label = utxoLabels[k], !label.isEmpty {
                                            Text(label)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.accentColor)
                                        }
                                        Text("\(formatKas(utxo.amount)) KAS")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("\(utxo.outpoint.transactionId.prefix(10))...:\(utxo.outpoint.index)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        if !selectedKeys.isEmpty {
                            Text("Selected: \(formatKas(selectedTotalSompi)) KAS (\(selectedKeys.count) UTXO\(selectedKeys.count == 1 ? "" : "s"))")
                        }
                    }
                }
            }
            .navigationTitle("Coin Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select All") { selectedKeys = Set(utxos.map(key)) }
                        Button("Automatic (Clear Selection)") { selectedKeys.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let selected = utxos.filter { selectedKeys.contains(key($0)) }
                    onDone(selected.isEmpty ? nil : selected)
                    dismiss()
                } label: {
                    Text(selectedKeys.isEmpty ? "Use Automatic Selection" : "Confirm Selection")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .task {
                utxoLabels = ColdStorageManager.shared.loadUtxoLabels(address: fromAddress)
                isLoading = true
                utxos = (try? await NodePoolService.shared.getUtxosByAddresses([fromAddress])) ?? []
                if let initialSelection {
                    selectedKeys = Set(initialSelection.map(key))
                }
                isLoading = false
            }
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }
}

/// Transaction history for a single Cold Storage address, opening each transaction directly on
/// whichever block explorer is selected in Settings > Connection > Kaspa Explorer.
private struct ColdStorageAddressTransactionHistoryView: View {
    let entry: ColdStorageAddressEntry

    /// The tapped transaction, while its action chooser is up.
    @State private var transactionActionTarget: KaspaFullTransactionResponse?
    @State private var pendingPortfolioCandidate: PortfolioCandidateTransaction?
    /// The transaction being filed into a portfolio, if any - see `AddToPortfolioSheet`.
    @State private var portfolioCandidate: PortfolioCandidateTransaction?
    /// Name of the portfolio just added to, for the confirmation capsule.
    @State private var addedPortfolioName: String?

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
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
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
            ToolbarItem(placement: .navigationBarTrailing) {
                if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                    Link(destination: url) {
                        Image(systemName: "globe")
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
            ColdStorageAddressQRView(entry: entry)
        }
        .sheet(isPresented: $showSendSheet) {
            ColdSendFlowView(fromAddress: entry.address, availableBalanceSompi: entry.balanceSompi) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            ColdSendFlowView(fromAddress: entry.address, availableBalanceSompi: entry.balanceSompi, isCompoundMode: true) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
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
                    ColdStorageManager.shared.setUtxoLabel(address: entry.address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = ColdStorageManager.shared.loadUtxoLabels(address: entry.address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = ColdStorageManager.shared.loadUtxoLabels(address: entry.address)
            await loadTransactions()
            await loadUtxos()
            await loadDomains()
        }
    }

    /// KNS domains owned by this cold storage address (same assets-by-owner lookup and teal
    /// KNSDomainCard rows as the spending-address KNS Domains tab). Deliberately watch-only:
    /// a KNS domain transfer is a commit/reveal inscription pair whose reveal input spends a
    /// P2SH redeem script, and the KSPT QR format KaChat and the KasSigner exchange only
    /// carries plain single-sig Schnorr inputs (KsptCodec rejects redeem-script payloads), so
    /// no send flow is offered here — see the footer note shown to the user.
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
                Section {
                    ForEach(knsDomains, id: \.inscriptionId) { domain in
                        KNSDomainCard(domain: domain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } footer: {
                    Text("Sending domains from a cold storage address requires signing on the KasSigner, which doesn't support inscription transactions yet.")
                        .padding(.horizontal, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadDomains()
        }
    }

    private func loadDomains() async {
        isLoadingDomains = true
        if let info = await KNSService.shared.fetchInfo(for: entry.address) {
            knsDomains = info.allDomains
            domainsLoadFailed = false
        } else {
            knsDomains = []
            domainsLoadFailed = true
        }
        isLoadingDomains = false
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
                address: entry.address,
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
        transactions = await ChatService.shared.fetchFullTransactionsPaginated(for: entry.address, pageSize: 200, maxTransactions: 200)
        isLoading = false
    }

    private func loadUtxos() async {
        isLoadingUtxos = true
        utxos = (try? await NodePoolService.shared.getUtxosByAddresses([entry.address])) ?? []
        isLoadingUtxos = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Bulk address-visibility checklist for one cold storage account: a paged list of EVERY
/// derived address (and, past the derived set, future indices derived on the fly) with a
/// whole-row check toggle. Mirrors Manage Addresses' SpendingAddressVisibilityView minus
/// the primary-address concept, which cold storage doesn't have.
private struct ColdStorageAddressVisibilityView: View {
    let account: ColdStorageAccount

    @ObservedObject private var manager = ColdStorageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ColdStorageAddressEntry] = []
    @State private var isLoading = true
    /// Lazily-filled history results for zero-balance addresses (address -> ever used).
    @State private var usedByAddress: [String: Bool] = [:]
    /// Pager: 50 addresses per page, endless - pages past the derived set derive future
    /// indices on the fly (checking one reveals it without flooding the main list).
    @State private var page = 0
    private let pageSize = 50
    private static let topAnchorID = "visibility_top"

    private var currentAccount: ColdStorageAccount {
        manager.accounts.first { $0.id == account.id } ?? account
    }

    /// The rows for the current page, by raw index order. Derived indices come from the
    /// loaded entries; anything beyond derives its address fresh (underived = unchecked).
    private var pageEntries: [ColdStorageAddressEntry] {
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        let start = page * pageSize
        return (start..<(start + pageSize)).compactMap { index in
            if let existing = byIndex[index] { return existing }
            guard let address = manager.address(for: currentAccount, at: index) else { return nil }
            return ColdStorageAddressEntry(index: index, address: address, balanceSompi: 0, hidden: true)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            // A zero-height anchor rather than scrolling to the first row: the
                            // row has its own insets, and scrolling to it left the list a few
                            // points down from the true top.
                            Color.clear
                                .frame(height: 0)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .id(Self.topAnchorID)
                            ForEach(pageEntries) { entry in
                                row(entry)
                            }
                        }
                        .listStyle(.plain)
                        // Turning the page keeps the scroll offset otherwise, so page 2 opened
                        // wherever page 1 was left - at the bottom, if that is where the pager
                        // was tapped from, which is the only place it can be tapped from.
                        .onChange(of: page) { _ in
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
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
        }
    }

    /// Bottom pager: "#start - #end" with arrows; the right arrow never runs out (pages past
    /// the derived set derive future addresses).
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

    private func row(_ entry: ColdStorageAddressEntry) -> some View {
        let funded = entry.balanceSompi > 0
        let visible = !entry.hidden
        return HStack(spacing: 10) {
            Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(visible ? .accentColor : .secondary)
                .opacity(funded ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("#\(entry.index)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
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
    private func usedTag(_ entry: ColdStorageAddressEntry, funded: Bool) -> some View {
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
        entries = await manager.getAddressList(for: currentAccount)
        isLoading = false
    }

    /// One history lookup per zero-balance address, cached for the session of this sheet.
    /// A failed probe stores nothing, so the row keeps its neutral "…" badge (never a
    /// possibly-wrong "Unused") and the next appearance of the row retries.
    private func ensureUsedLoaded(_ entry: ColdStorageAddressEntry, funded: Bool) async {
        guard !funded, usedByAddress[entry.address] == nil else { return }
        if let used = await ChatService.shared.spendingAddressUsedState(entry.address) {
            usedByAddress[entry.address] = used
        }
    }

    private func toggle(_ entry: ColdStorageAddressEntry) {
        // Funded rows don't toggle - mirrors the manager-side guard.
        guard entry.balanceSompi == 0 else { return }
        Task {
            let derivedMax = entries.map(\.index).max() ?? -1
            if entry.index > derivedMax {
                // A derived future index from the endless pager: reveal exactly this one
                // (indices in between stay hidden so the main list doesn't flood).
                manager.revealAddress(for: currentAccount, at: entry.index)
                entries = await manager.getAddressList(for: currentAccount)
            } else {
                let ok = await manager.setAddressHidden(account: currentAccount, index: entry.index, hidden: !entry.hidden)
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


/// The half sheet behind an account's ellipsis, replacing the menu that was there.
///
/// Renaming happens in place rather than by dismissing into an alert: the sheet is already the
/// context for "this account", and bouncing out to a system alert to type one word threw that
/// away. Cancel walks back to the options rather than closing, so a mis-tap costs nothing.
private struct ColdStorageAccountActionsSheet: View {
    let account: ColdStorageAccount
    let onCopyKpub: () -> Void
    let onShowKpubQR: () -> Void
    let onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var nameText = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(isRenaming ? "Rename Account" : account.label)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            if isRenaming { renameFields } else { options }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // One fixed height for both states: a detent that changes while the sheet is up
        // resizes in a jump rather than animating, and the rename fields fit the options' height.
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .animation(.easeInOut(duration: 0.2), value: isRenaming)
    }

    private var options: some View {
        VStack(spacing: 12) {
            ActionSheetRow(
                title: "Copy kpub",
                subtitle: "Puts the extended public key on the clipboard.",
                systemImage: "doc.on.doc"
            ) {
                onCopyKpub()
                dismiss()
            }
            ActionSheetRow(
                title: "Show kpub QR",
                subtitle: "Scan it into another device to watch this account there.",
                systemImage: "qrcode"
            ) {
                onShowKpubQR()
                dismiss()
            }
            ActionSheetRow(
                title: "Rename",
                subtitle: "Changes the name shown for this account.",
                systemImage: "pencil"
            ) {
                nameText = account.label
                isRenaming = true
                // A turn later: the field does not exist yet on the tap that reveals it.
                DispatchQueue.main.async { nameFocused = true }
            }
        }
    }

    private var renameFields: some View {
        VStack(spacing: 12) {
            TextField("Name", text: $nameText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit(save)
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { isRenaming = false }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Save", action: save)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(trimmedName.isEmpty ? 0.4 : 1))
                    )
                    .disabled(trimmedName.isEmpty)
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onRename(trimmedName)
        Haptics.success()
        dismiss()
    }
}

/// The kpub of one cold-storage account, as a QR for moving it to another device or a watch-only
/// wallet elsewhere.
///
/// Deliberately says what a kpub is. It holds no private key and cannot spend anything, which is
/// why it is safe to display at all - but it derives EVERY address in the account, so whoever
/// scans it can watch the whole balance and history forever. That is a privacy decision the
/// person holding the phone should get to make knowingly, not discover later.
private struct ColdStorageKpubQRView: View {
    let account: ColdStorageAccount
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
                                    .frame(width: 260, height: 260)
                            } else {
                                ProgressView()
                                    .frame(width: 260, height: 260)
                            }
                        }
                        .padding(20)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        Text(account.kpubString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color.black.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Text("Watch-only. This cannot spend, but it reveals every address in this account.")
                            .font(.footnote)
                            .foregroundColor(Color.black.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Text("Tap anywhere to copy")
                            .font(.footnote)
                            .foregroundColor(Color.black.opacity(0.4))

                        Spacer()
                        Spacer()
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { copyKpub() }
                .navigationTitle(account.label)
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

    private func copyKpub() {
        UIPasteboard.general.string = account.kpubString
        Haptics.success()
        showToast("kpub copied to clipboard.")
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
        let kpub = account.kpubString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kpub.isEmpty, let data = kpub.data(using: .utf8) else { return }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        // "L" where the address QR uses "M": a kpub is several times longer, and at "M" the extra
        // error-correction pushes the symbol into a denser version that scans worse on screen
        // than the lower correction level does. Nothing is being transmitted over a lossy channel
        // here - it is one screen photographed by one camera.
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        qrImage = UIImage(cgImage: cgImage)
    }
}
