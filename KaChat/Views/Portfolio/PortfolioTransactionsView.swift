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
    @State private var showCsvExporter = false
    @State private var exportURL: URL?
    @State private var toastMessage: String?
    @State private var toastStyle: ToastStyle = .success
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
                    toastStyle = .success
                    let base = "Imported \(importResult.imported.count) transaction\(importResult.imported.count == 1 ? "" : "s")"
                    toastMessage = importResult.missingPriceCount > 0
                        ? base + " (\(importResult.missingPriceCount) need a price — edit to set manually)"
                        : base
                case .failure(let error):
                    toastStyle = .error
                    toastMessage = error.errorDescription ?? "Import failed."
                }
            }
        }
        .sheet(isPresented: $showCsvExporter) {
            if let exportURL {
                PortfolioCsvShareSheet(fileURL: exportURL)
            }
        }
        .fileImporter(isPresented: $showCsvImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                let count = viewModel.importCsv(from: url)
                toastStyle = count > 0 ? .success : .error
                toastMessage = count > 0 ? "Imported \(count) transaction\(count == 1 ? "" : "s")" : "Import failed. Check the CSV format"
            case .failure:
                toastStyle = .error
                toastMessage = "Import failed. Check the CSV format"
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
        let needsPrice = tx.notes == PortfolioAddressImporter.priceUnavailableNote
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
                            .accessibilityLabel("Price needed — tap to set")
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
                exportURL = viewModel.exportCsvURL()
                showCsvExporter = exportURL != nil
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
private struct AddPortfolioAddressSheet: View {
    @ObservedObject var viewModel: PortfolioViewModel
    let onCompletion: (Result<PortfolioAddressImporter.ImportResult, PortfolioAddressImporter.ImportError>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var isImporting = false
    @State private var progressText = "Starting…"

    private var isValidAddress: Bool {
        KaspaAddress.isValid(addressText.trimmingCharacters(in: .whitespacesAndNewlines))
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
                        TextField("kaspa:qr...", text: $addressText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } footer: {
                        Text("Every received transaction on this address becomes a buy, every sent transaction becomes a sell, priced at that day's historical KAS price. Re-adding the same address later only imports transactions found since the last import.")
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
                    .disabled(!isValidAddress || isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func startImport() {
        isImporting = true
        let address = addressText
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
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Fee (optional)")
                        Spacer()
                        Text(currencySymbol)
                            .foregroundColor(.secondary)
                        TextField("0.00", text: $feeText)
                            .keyboardType(.decimalPad)
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
