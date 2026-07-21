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
    @State private var renameTarget: ColdStorageAccount?
    @State private var renameText = ""
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
                        .foregroundColor(.accentColor)
                        .background(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
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
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage)
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
            Button("Import") {
                completeImport()
            }
            .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingKpub = nil
            }
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
        .alert(
            "Rename Cold Storage Account",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renameTarget {
                    manager.renameAccount(renameTarget, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
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
            Menu {
                Button {
                    UIPasteboard.general.string = account.kpubString
                    Haptics.success()
                    showToast("kpub copied to clipboard.")
                } label: {
                    Label("Copy kpub", systemImage: "doc.on.doc")
                }
                Button {
                    renameText = account.label
                    renameTarget = account
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .tint(.accentColor)
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
    @State private var qrTarget: ColdStorageAddressEntry?
    @State private var sendTarget: ColdStorageAddressEntry?
    @State private var renameTarget: ColdStorageAddressEntry?
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var currentAccount: ColdStorageAccount {
        manager.accounts.first { $0.id == account.id } ?? account
    }

    private var visibleEntries: [ColdStorageAddressEntry] {
        entries.filter { !$0.hidden }
            .sorted { lhs, rhs in
                if (lhs.balanceSompi > 0) != (rhs.balanceSompi > 0) {
                    return lhs.balanceSompi > 0
                }
                return lhs.index > rhs.index
            }
    }

    private var hiddenCount: Int {
        entries.filter { $0.hidden }.count
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

            if hiddenCount > 0 {
                NavigationLink {
                    HiddenColdStorageAddressesView(account: currentAccount)
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
                        .swipeActions(edge: .trailing) {
                            if entry.balanceSompi == 0 {
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
                    generateMore()
                } label: {
                    Label("Generate More Addresses", systemImage: "plus.circle")
                }
                Button {
                    discoverAddresses()
                } label: {
                    Label("Discover Addresses", systemImage: "magnifyingglass")
                }
            } label: {
                Group {
                    if isGenerating || isDiscovering {
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
            .disabled(isGenerating || isDiscovering)
        }
        .navigationTitle(currentAccount.label)
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .refreshable {
            await loadEntries()
        }
        .task {
            await loadEntries()
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(currentAccount.label)
                    .fontWeight(.semibold)
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
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(formatKasExact(totalBalanceSompi)) KAS")
                    .font(.title2)
                    .fontWeight(.bold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func addressRow(_ entry: ColdStorageAddressEntry) -> some View {
        let isUsed = entry.everUsed || entry.balanceSompi > 0

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
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(entry.shortAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("\(formatKasExact(entry.balanceSompi)) KAS")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(isUsed ? "Used" : "Unused")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(isUsed ? .orange : .green)
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
                    if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                        Link(destination: url) {
                            Label("View in Explorer", systemImage: "safari")
                        }
                    }
                    if entry.balanceSompi > 0 {
                        Button {
                            sendTarget = entry
                        } label: {
                            Label("Send From This Address", systemImage: "arrow.up.circle")
                        }
                    }
                    Button {
                        renameText = entry.label ?? ""
                        renameTarget = entry
                    } label: {
                        Label("Rename Address", systemImage: "pencil")
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
        }
        .background(glassBackground(cornerRadius: 18))
    }

    private func loadEntries() async {
        isLoading = true
        let baseEntries = await manager.getAddressList(for: currentAccount)

        // Sequential, not concurrent — same rate-limit reasoning as Manage Addresses'
        // spending-chain "used" check.
        var updated: [ColdStorageAddressEntry] = []
        for entry in baseEntries {
            if entry.balanceSompi > 0 {
                updated.append(entry)
                continue
            }
            var copy = entry
            copy.everUsed = await ChatService.shared.hasSpendingAddressBeenUsed(entry.address)
            updated.append(copy)
        }
        entries = updated.sorted { $0.index < $1.index }
        isLoading = false
    }

    private func hideAddress(_ entry: ColdStorageAddressEntry) {
        Task {
            let hidden = manager.setAddressHidden(accountId: currentAccount.id, index: entry.index, hidden: true, balanceSompi: entry.balanceSompi)
            if hidden {
                await loadEntries()
            }
        }
    }

    private func generateMore() {
        guard !isGenerating else { return }
        isGenerating = true
        manager.generateNextAddress(for: currentAccount)
        Task {
            await loadEntries()
            isGenerating = false
        }
    }

    private func discoverAddresses() {
        guard !isDiscovering else { return }
        isDiscovering = true
        Task {
            _ = await manager.discoverAddresses(for: currentAccount)
            await loadEntries()
            isDiscovering = false
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

                        Spacer()
                        Spacer()
                    }
                )
                .navigationTitle(entry.displayLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
                .onAppear { generateQR() }
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
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsViewModel: SettingsViewModel

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
    @State private var feeRateOverride: UInt64?
    @State private var showFeeEditor = false
    @State private var feeEditorInput = ""

    private var amountSompi: UInt64? {
        guard let kas = Double(amountText), kas > 0 else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    private var canBuild: Bool {
        isValidAddress && amountSompi != nil
    }

    /// Reference-mass fee shown/edited here, matching Android's ColdSendFlow exactly: a fixed
    /// 1-input/2-standard-output mass, not the real per-send mass (which depends on how many
    /// UTXOs actually get selected and isn't known until build time) — good enough for the user
    /// to reason about "pay more to confirm faster" without an extra network round trip just to
    /// populate this label.
    private var referenceMass: UInt64 { ColdStorageSendEngine.referenceMassForFeeEditor }

    private var defaultFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: KaspaFeePolicy.minimumRelayFeePerGramSompi)
    }

    private var effectiveFeeSompi: UInt64 {
        guard let feeRateOverride else { return defaultFeeSompi }
        return ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: feeRateOverride)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .form, .building:
                    formView
                case .showingQR(_, let frames):
                    qrView(frames: frames)
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
            .navigationTitle("Send from Cold Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
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
                TextField("kaspa:qr...", text: $toAddress)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: toAddress) { isValidAddress = KaspaAddress.isValid($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

                if !toAddress.isEmpty {
                    HStack {
                        Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isValidAddress ? .green : .red)
                        Text(isValidAddress ? "Valid address" : "Invalid address format")
                            .font(.caption)
                            .foregroundColor(isValidAddress ? .green : .red)
                    }
                }

                HStack {
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            toAddress = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
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
            } header: {
                Text("Recipient Address")
            }

            Section {
                HStack {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                    if isEstimatingMax {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Button("Max") {
                            setMaxAmount()
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .buttonStyle(.borderless)
                        .disabled(!isValidAddress)
                    }
                    Text("KAS")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Amount")
            }

            Section {
                Button {
                    feeEditorInput = formatKasTrimmed(effectiveFeeSompi)
                    showFeeEditor = true
                } label: {
                    HStack {
                        Text("Network Fee")
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(formatKas(effectiveFeeSompi)) KAS")
                            .underline()
                            .foregroundColor(.accentColor)
                    }
                }
            } footer: {
                Text("Tap to adjust. If the network is busy, a higher fee can help your transaction confirm faster.")
            }

            if case .failed(let message) = step {
                Section {
                    Text(message)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if case .building = step {
                    ProgressView()
                } else {
                    Button("Next") {
                        buildTransaction()
                    }
                    .disabled(!canBuild)
                }
            }
        }
        .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
            TextField("Fee (KAS)", text: $feeEditorInput)
                .keyboardType(.decimalPad)
            Button("Save") {
                if let kas = Double(feeEditorInput), kas > 0 {
                    let desiredFeeSompi = UInt64((kas * 100_000_000).rounded())
                    let rate = UInt64((Double(desiredFeeSompi) / Double(referenceMass)).rounded(.up))
                    feeRateOverride = max(rate, 1)
                } else {
                    feeRateOverride = nil
                }
            }
            Button("Use Default") {
                feeRateOverride = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the network is busy, a higher fee can help your transaction confirm faster.\n\nDefault: \(formatKas(defaultFeeSompi)) KAS")
        }
    }

    /// Literal white background regardless of system dark/light mode — matching this app's
    /// established convention for any screen showing a QR meant to be read by another device's
    /// camera (see ChattingAddressQRView/ColdStorageAddressQRView), and a real, plausible fix
    /// for a scan a KasSigner device failed to read: a dark surrounding background gives a
    /// phone camera photographing this screen far less contrast/exposure headroom around the
    /// code than a bright white one does.
    private func qrView(frames: [Data]) -> some View {
        Color.white
            .ignoresSafeArea()
            .overlay(
                ScrollView {
                    VStack(spacing: 20) {
                        Text("Scan this on your KasSigner device")
                            .font(.subheadline)
                            .foregroundColor(Color.black.opacity(0.6))
                        AnimatedQRDisplayView(frames: frames, displaySize: 280)
                        Button {
                            if case .showingQR(let unsignedTx, _) = step {
                                step = .scanning(unsignedTx)
                            }
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
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("Transaction Sent")
                .font(.title3)
                .fontWeight(.semibold)
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                Link(destination: url) {
                    Text(txId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text(txId)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
            }
            Button("Done") {
                onDone()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        isValidAddress = KaspaAddress.isValid(address)
    }

    private func setMaxAmount() {
        guard isValidAddress else { return }
        isEstimatingMax = true
        let overrideRate = feeRateOverride
        Task {
            do {
                let maxSompi = try await ColdStorageSendEngine.shared.estimateMaxAmount(fromAddress: fromAddress, feeRateOverride: overrideRate)
                await MainActor.run {
                    amountText = formatKasTrimmed(maxSompi)
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
        let recipient = toAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideRate = feeRateOverride
        Task {
            do {
                let unsignedTx = try await ColdStorageSendEngine.shared.buildUnsignedTransaction(
                    fromAddress: fromAddress,
                    toAddress: recipient,
                    amountSompi: amountSompi,
                    feeRateOverride: overrideRate
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

    private func formatKasTrimmed(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Transaction history for a single Cold Storage address, opening each transaction directly on
/// whichever block explorer is selected in Settings > Connection > Kaspa Explorer.
private struct ColdStorageAddressTransactionHistoryView: View {
    let entry: ColdStorageAddressEntry

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
        .navigationTitle(entry.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTransactions()
        }
        .refreshable {
            await loadTransactions()
        }
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
        transactions = await ChatService.shared.fetchFullTransactionsPaginated(for: entry.address, pageSize: 50, maxTransactions: 200)
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Addresses hidden from the main Cold Storage detail list (swipe-to-hide there). Never
/// includes an address with a balance — those can't be hidden in the first place.
private struct HiddenColdStorageAddressesView: View {
    let account: ColdStorageAccount

    @ObservedObject private var manager = ColdStorageManager.shared

    @State private var entries: [ColdStorageAddressEntry] = []
    @State private var isLoading = false

    private var hiddenEntries: [ColdStorageAddressEntry] {
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

    private func addressRow(_ entry: ColdStorageAddressEntry) -> some View {
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
        entries = await manager.getAddressList(for: account)
        isLoading = false
    }

    private func unhide(_ entry: ColdStorageAddressEntry) {
        Task {
            _ = manager.setAddressHidden(accountId: account.id, index: entry.index, hidden: false, balanceSompi: entry.balanceSompi)
            await loadEntries()
        }
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }
}
