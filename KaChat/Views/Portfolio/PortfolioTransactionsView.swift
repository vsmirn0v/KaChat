import SwiftUI
import UniformTypeIdentifiers

/// Shared formatter at file scope - the view is generic now (header slot), and generic types
/// can't carry static stored properties.
private let kasAmountFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 4
    formatter.locale = Locale(identifier: "en_US")
    return formatter
}()

/// Identifiable wrapper so the CSV share sheet can be presented with `.sheet(item:)`. The old
/// code paired a `Bool` with a separate `URL?` state and read that URL back inside the sheet's
/// content closure, which SwiftUI evaluates against the view value from before the tap - the URL
/// was still nil there, the `if let` fell through to an empty body, and the user got a blank
/// sheet. Carrying the URL as the presentation item makes that impossible.
private struct PortfolioCsvExport: Identifiable {
    let id = UUID()
    let url: URL
}

struct PortfolioTransactionsView<Header: View>: View {
    @ObservedObject var viewModel: PortfolioViewModel
    /// Rendered above the Transactions section - PortfolioView passes the picker cards and
    /// data cards here so the whole page is ONE list (continuous scroll, native large-title
    /// collapse, transactions reachable by just scrolling).
    @ViewBuilder let header: () -> Header
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    @State private var editingTransaction: PortfolioTransaction?
    @State private var showAddSheet = false
    @State private var showAddAddressSheet = false
    @State private var showCsvImporter = false
    @State private var csvExport: PortfolioCsvExport?
    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success
    @State private var toastToken = UUID()
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<String>()
    @State private var showDeleteSelectedConfirm = false

    private var isSelecting: Bool { editMode == .active }

    var body: some View {
        List(selection: $selectedIDs) {
            header()

            Section {
                if viewModel.transactionsDescending.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.transactionsDescending) { tx in
                        Button {
                            editingTransaction = tx
                        } label: {
                            transactionRow(tx)
                        }
                        .buttonStyle(.plain)
                        .tag(tx.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel.deleteTransaction(id: tx.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            } header: {
                // Add + import/export live right on the section header now, replacing the old
                // floating overlay buttons.
                HStack(spacing: 16) {
                    Text("Transactions")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .textCase(nil)
                    Spacer()
                    addTransactionButton
                    importExportButton
                }
                .padding(.bottom, 2)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refreshPriceAsync()
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Menu {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Label(
                                selectedIDs.count == viewModel.transactionsDescending.count ? "Deselect All" : "Select All",
                                systemImage: "checkmark.circle"
                            )
                        }
                        Button(role: .destructive) {
                            showDeleteSelectedConfirm = true
                        } label: {
                            Label("Delete Selected (\(selectedIDs.count))", systemImage: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(.accentColor)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    withAnimation {
                        if isSelecting {
                            editMode = .inactive
                            selectedIDs.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                }
                .disabled(viewModel.transactionsDescending.isEmpty && !isSelecting)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            PortfolioTransactionEditor(viewModel: viewModel, existing: nil)
        }
        .sheet(item: $editingTransaction) { tx in
            PortfolioTransactionEditor(viewModel: viewModel, existing: tx)
        }
        .sheet(isPresented: $showAddAddressSheet) {
            AddPortfolioAddressSheet(viewModel: viewModel) { result in
                switch result {
                case .success(let importResult):
                    var message = "Imported \(importResult.imported.count) transaction\(importResult.imported.count == 1 ? "" : "s")"
                    if importResult.missingPriceCount > 0 {
                        message += ". Prices for \(importResult.missingPriceCount) are still loading and will fill in automatically"
                    }
                    if !importResult.historyComplete {
                        message += ". Some history couldn't be fetched, re-add this address later to import the rest"
                    }
                    showToast(message)
                case .failure(let error):
                    showToast(error.errorDescription ?? "Import failed.", style: .error)
                }
            }
        }
        .sheet(item: $csvExport) { export in
            PortfolioCsvShareSheet(fileURL: export.url)
        }
        .fileImporter(isPresented: $showCsvImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                let count = viewModel.importCsv(from: url)
                toastStyle = count > 0 ? .success : .error
                showToast(count > 0 ? "Imported \(count) transaction\(count == 1 ? "" : "s")" : "Import failed. Check the CSV format", style: count > 0 ? .success : .error)
            case .failure:
                toastStyle = .error
                showToast("Import failed. Check the CSV format", style: .error)
            }
        }
        .toast(message: toastMessage, style: toastStyle)
        .alert(
            "Delete \(selectedIDs.count) Transaction\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteSelectedConfirm
        ) {
            Button("Delete", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    private func toggleSelectAll() {
        if selectedIDs.count == viewModel.transactionsDescending.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(viewModel.transactionsDescending.map { $0.id })
        }
    }

    private func deleteSelected() {
        for id in selectedIDs {
            viewModel.deleteTransaction(id: id)
        }
        selectedIDs.removeAll()
        editMode = .inactive
    }

    /// Builds the CSV first and only presents once there is a real file on disk. A header-only
    /// export (no transactions in this portfolio) and a failed write both surface as a toast
    /// instead of an empty share sheet.
    private func exportCsv() {
        guard !viewModel.scopedTransactions.isEmpty else {
            showToast("Nothing to export yet. Add a transaction first", style: .error)
            return
        }
        guard let url = viewModel.exportCsvURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            showToast("Export failed. Couldn't write the CSV file", style: .error)
            return
        }
        csvExport = PortfolioCsvExport(url: url)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No Transactions Yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Add a buy or sell to start tracking your portfolio")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func transactionRow(_ tx: PortfolioTransaction) -> some View {
        let needsPrice = PortfolioAddressImporter.isPricePending(tx.notes)
        return HStack(spacing: 12) {
            Image(systemName: tx.type == .buy ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundColor(tx.type == .buy ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(tx.type == .buy ? "Buy" : "Sell")
                        .fontWeight(.medium)
                    if needsPrice {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                            .accessibilityLabel("Price still loading, tap to set manually")
                    }
                }
                Text(tx.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let notes = tx.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Self.formatKasAmount(tx.amountKas)) KAS")
                    .fontWeight(.medium)
                Text(formatCurrency(tx.fiatValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }


    /// Comma-grouped for display only (e.g. "12,345.6789 KAS") — never used for a value that
    /// gets parsed back, unlike the plain, non-grouped formatting the editable quantity field uses.
    private static func formatKasAmount(_ value: Double) -> String {
        kasAmountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
    }

    private var addTransactionButton: some View {
        Menu {
            Button {
                Haptics.impact(.light)
                showAddSheet = true
            } label: {
                Label("Add Transaction", systemImage: "pencil")
            }
            Button {
                Haptics.impact(.light)
                showAddAddressSheet = true
            } label: {
                Label("Add Kaspa Address", systemImage: "arrow.left.arrow.right")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
        }
        .tint(.accentColor)
    }

    private var importExportButton: some View {
        Menu {
            Button {
                showCsvImporter = true
            } label: {
                Label("Import CSV", systemImage: "square.and.arrow.down")
            }
            Button {
                Haptics.impact(.light)
                exportCsv()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .tint(.accentColor)
    }

    /// Manual build via a plain symbol prefix rather than `.formatted(.currency(code:))` - the
    /// latter is Foundation's ISO-4217-driven `FormatStyle`, whose behavior for a non-ISO-4217
    /// code like `.bitcoin`'s "BTC" isn't something to rely on sight-unseen.
    private func formatCurrency(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let symbol = settingsViewModel.settings.currency == .bitcoin ? "₿" : {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = settingsViewModel.settings.currency.code
            return formatter.currencySymbol ?? settingsViewModel.settings.currency.code
        }()
        let decimalFormatter = NumberFormatter()
        decimalFormatter.numberStyle = .decimal
        decimalFormatter.minimumFractionDigits = 2
        decimalFormatter.maximumFractionDigits = 2
        decimalFormatter.usesGroupingSeparator = true
        let magnitude = decimalFormatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return sign + symbol + magnitude
    }
}

private struct PortfolioCsvShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Add Kaspa Address

/// Address entry -> fetch/classify/price progress, all in one sheet. Every received transaction
/// on the address becomes a buy, every sent transaction becomes a sell (see
/// `PortfolioAddressImporter`) — deliberately no attempt to filter out ordinary KaChat payments
/// or protocol overhead, a simplification the user explicitly chose over building a "real trade"
/// classifier.
///
/// The field accepts a raw kaspa:/kaspatest: address OR a KNS domain (e.g. alice.kas), with
/// paste/scan helpers — the KNS live-resolve + Paste/Scan QR row mirrors the withdraw flow in
/// `ManageAddressesView` (same debounce, same `QRScannerView`). A valid domain imports its
/// RESOLVED address; portfolio rows have no display-label field, so the domain itself isn't
/// stored (rows dedupe/group purely by `sourceAddress`).
private struct AddPortfolioAddressSheet: View {
    @ObservedObject var viewModel: PortfolioViewModel
    let onCompletion: (Result<PortfolioAddressImporter.ImportResult, PortfolioAddressImporter.ImportError>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var isImporting = false
    @State private var progressText = "Starting…"
    @State private var showQRScanner = false

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    @State private var knsNotFound = false

    private var trimmedInput: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var looksLikeRawAddress: Bool {
        trimmedInput.hasPrefix("kaspa:") || trimmedInput.hasPrefix("kaspatest:")
    }

    private var isValidRawAddress: Bool {
        KaspaAddress.isValid(trimmedInput)
    }

    /// The address the import actually runs on — resolved from a KNS domain when one was
    /// entered, otherwise the raw input. Same precedence as ManageAddressesView's withdraw flow.
    private var effectiveAddress: String {
        resolvedAddress ?? trimmedInput
    }

    private var canImport: Bool {
        resolvedAddress != nil || isValidRawAddress
    }

    var body: some View {
        NavigationStack {
            Form {
                if isImporting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(progressText)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section {
                        TextField("kaspa:qr... or name.kas", text: $addressText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: addressText) { handleInputChange($0) }

                        validationStatus

                        HStack {
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    addressText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    } footer: {
                        Text("Enter a Kaspa address or a KNS domain like name.kas. Every received transaction on this address becomes a buy, every sent transaction becomes a sell, priced at that day's historical KAS price. Re-adding the same address later only imports transactions found since the last import.")
                    }
                }
            }
            .navigationTitle("Add Kaspa Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        startImport()
                    }
                    .disabled(!canImport || isImporting)
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    /// Under-field status line: nothing while empty or mid-debounce, "Resolves to" + green
    /// check for a resolved domain, a quiet "Domain not found", or the raw address's
    /// valid/invalid affordance (same shape as ManageAddressesView's withdraw flow).
    @ViewBuilder
    private var validationStatus: some View {
        if trimmedInput.isEmpty || isResolvingKNS {
            EmptyView()
        } else if let resolvedAddress {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Resolves to \(Self.shortened(resolvedAddress))")
                    .font(.caption)
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
        } else if knsNotFound {
            Text("Domain not found")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if looksLikeRawAddress {
            HStack(spacing: 6) {
                Image(systemName: isValidRawAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isValidRawAddress ? .green : .red)
                Text(isValidRawAddress ? "Valid address" : "Invalid address format")
                    .font(.caption)
                    .foregroundColor(isValidRawAddress ? .green : .red)
            }
        }
    }

    private static func shortened(_ address: String) -> String {
        guard address.count > 26 else { return address }
        return "\(address.prefix(16))...\(address.suffix(8))"
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsNotFound = false
        isResolvingKNS = false

        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") { return }
        if KNSService.looksLikeDomain(trimmed) {
            resolveKNSDomain(trimmed)
        }
    }

    /// Debounced forward resolution — same 300ms wait-then-check-input-unchanged pattern the
    /// contacts/withdraw flows use, so mid-typing keystrokes never each fire a KNS request.
    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard addressText.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }

            let resolution = await KNSService.shared.resolveDomain(domain)
            await MainActor.run {
                // Input may have moved on while the lookup was in flight — a stale answer
                // must not overwrite the state for what's in the field now.
                guard addressText.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                if let resolution {
                    resolvedAddress = resolution.ownerAddress
                    resolvedDomain = resolution.domain
                    knsNotFound = false
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    knsNotFound = true
                }
                isResolvingKNS = false
            }
        }
    }

    /// Same normalization as ManageAddressesView's scan handler: strip URI query params
    /// (kaspa:addr?amount=...) so only the address itself lands in the field. Setting
    /// `addressText` triggers `handleInputChange` via `.onChange`.
    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        addressText = address
    }

    private func startImport() {
        isImporting = true
        let address = effectiveAddress
        Task {
            let result = await viewModel.importAddress(address) { text in
                Task { @MainActor in
                    progressText = text
                }
            }
            await MainActor.run {
                dismiss()
                onCompletion(result)
            }
        }
    }
}

// MARK: - Add/Edit editor

private struct PortfolioTransactionEditor: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    let existing: PortfolioTransaction?
    @Environment(\.dismiss) private var dismiss

    @State private var isBuy: Bool
    @State private var quantityText: String
    @State private var priceText: String
    @State private var feeText: String = ""
    @State private var notesText: String
    @State private var timestamp: Date

    init(viewModel: PortfolioViewModel, existing: PortfolioTransaction?) {
        self.viewModel = viewModel
        self.existing = existing
        _isBuy = State(initialValue: existing?.type != .sell)
        _notesText = State(initialValue: existing?.notes ?? "")
        _timestamp = State(initialValue: existing?.timestamp ?? Date())

        if let existing, existing.amountKas > 0 {
            _quantityText = State(initialValue: Self.trimmedNumber(existing.amountKas))
            _priceText = State(initialValue: Self.trimmedNumber(existing.fiatValue / existing.amountKas))
        } else {
            _quantityText = State(initialValue: "")
            // New transaction: prefill with the live price so the common case (recording a
            // trade that just happened) needs no manual lookup — still fully editable for
            // backdated entries.
            _priceText = State(initialValue: viewModel.currentPriceUsd.map(Self.trimmedNumber) ?? "")
        }
    }

    private var quantity: Double? { Double(quantityText) }
    private var pricePerCoin: Double? { Double(priceText) }
    private var fee: Double { Double(feeText) ?? 0 }

    private var total: Double? {
        guard let quantity, let pricePerCoin else { return nil }
        let base = quantity * pricePerCoin
        return isBuy ? base + fee : base - fee
    }

    private var currencySymbol: String {
        if settingsViewModel.settings.currency == .bitcoin { return "₿" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settingsViewModel.settings.currency.code
        return formatter.currencySymbol ?? settingsViewModel.settings.currency.code
    }

    /// Manual build via `currencySymbol` rather than `.formatted(.currency(code:))` - the latter
    /// is Foundation's ISO-4217-driven `FormatStyle`, whose behavior for a non-ISO-4217 code like
    /// `.bitcoin`'s "BTC" isn't something to rely on sight-unseen.
    private func formatCurrency(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return sign + currencySymbol + magnitude
    }

    private var isValid: Bool {
        (quantity ?? 0) > 0 && (pricePerCoin ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isBuy) {
                        Text("Buy").tag(true)
                        Text("Sell").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("0.00", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .numericKeyboardDoneButton()
                            .multilineTextAlignment(.trailing)
                        Text("KAS")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Price Per Coin")
                        Spacer()
                        Text(currencySymbol)
                            .foregroundColor(.secondary)
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .numericKeyboardDoneButton()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Fee (optional)")
                        Spacer()
                        Text(currencySymbol)
                            .foregroundColor(.secondary)
                        TextField("0.00", text: $feeText)
                            .keyboardType(.decimalPad)
                            .numericKeyboardDoneButton()
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $timestamp, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    TextField("Notes (optional)", text: $notesText, axis: .vertical)
                }

                Section {
                    HStack {
                        Text(isBuy ? "Total Spent" : "Total Received")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatCurrency(total ?? 0))
                            .fontWeight(.semibold)
                    }
                }

                if existing != nil {
                    Section {
                        Button("Delete Transaction", role: .destructive) {
                            if let existing {
                                viewModel.deleteTransaction(id: existing.id)
                            }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(existing == nil ? "Add" : "Save") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        guard let quantity, let total else { return }
        let type: PortfolioTransactionType = isBuy ? .buy : .sell
        let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes = notes.isEmpty ? nil : notes

        if let existing {
            viewModel.updateTransaction(
                id: existing.id,
                type: type,
                amountKas: quantity,
                fiatValue: total,
                timestamp: timestamp,
                notes: finalNotes
            )
        } else {
            viewModel.addTransaction(
                type: type,
                amountKas: quantity,
                fiatValue: total,
                timestamp: timestamp,
                notes: finalNotes
            )
        }
        dismiss()
    }

    private static func trimmedNumber(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
