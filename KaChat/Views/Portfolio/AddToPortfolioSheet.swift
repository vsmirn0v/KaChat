import SwiftUI

/// One on-chain transaction, ready to become a portfolio ledger row.
///
/// Built from a `KaspaFullTransactionResponse` plus the address it was viewed under, so the same
/// sheet serves cold-storage history, spending-address history and the chatting address without
/// any of them knowing what a portfolio row looks like.
struct PortfolioCandidateTransaction: Identifiable, Equatable {
    let txId: String
    let address: String
    let amountKas: Double
    let isOutgoing: Bool
    let timestamp: Date

    var id: String { txId }

    /// Nil when the transaction has no side involving `address` we can price - a pure internal
    /// move, or a shape `direction(for:)` cannot read.
    init?(transaction: KaspaFullTransactionResponse, address: String) {
        guard let info = transaction.direction(for: address) else { return nil }
        txId = transaction.transactionId
        self.address = address
        amountKas = Double(info.amountSompi) / 100_000_000.0
        isOutgoing = info.isOutgoing
        // A transaction with no block time yet is still in the mempool; "now" is the honest
        // stand-in and the date is editable anyway.
        timestamp = transaction.blockTime.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
    }
}

/// Adds an on-chain transaction to a portfolio: pick the portfolio, then check over what is
/// being recorded, then confirm.
///
/// Two steps rather than one long form. The portfolio is the decision that changes what
/// everything else means, and a medium detent cannot hold a picker AND five fields without
/// becoming a scroll. Presented at `.medium` like the portfolio card sheet, so this reads as the
/// same kind of object.
struct AddToPortfolioSheet: View {
    let candidate: PortfolioCandidateTransaction
    /// Called after a successful add, so the caller can show its own confirmation.
    var onAdded: ((Portfolio) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var portfolioManager = PortfolioManager.shared
    @ObservedObject private var viewModel = PortfolioViewModel.shared

    private enum Step { case choosePortfolio, editDetails }
    @State private var step: Step = .choosePortfolio
    @State private var selected: Portfolio?

    @State private var type: PortfolioTransactionType = .buy
    @State private var amountText = ""
    @State private var priceText = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var isLookingUpPrice = false
    @State private var alreadyInPortfolio = false

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    private var amount: Double? { Self.number(from: amountText) }
    private var pricePerKas: Double? { Self.number(from: priceText) }
    private var totalValue: Double? {
        guard let amount, let pricePerKas else { return nil }
        return amount * pricePerKas
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choosePortfolio: choosePortfolio
                case .editDetails: editDetails
                }
            }
            .navigationTitle(step == .choosePortfolio ? "Add to Portfolio" : "Transaction Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .editDetails {
                        Button("Back") { withAnimation { step = .choosePortfolio } }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .editDetails {
                        Button("Confirm") { confirm() }
                            .fontWeight(.semibold)
                            .disabled(amount == nil || amount == 0)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: prefill)
    }

    // MARK: - Step 1

    private var choosePortfolio: some View {
        List {
            Section {
                ForEach(portfolioManager.portfolios) { portfolio in
                    Button {
                        Haptics.impact(.light)
                        selected = portfolio
                        checkForDuplicate(in: portfolio)
                        withAnimation { step = .editDetails }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(portfolio.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                // Flagged here, not only after selecting: the point of the
                                // warning is to be seen while the choice is still being made.
                                if duplicatePortfolioIds.contains(portfolio.id) {
                                    Label("Already added", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.orange)
                                } else if portfolio.id == portfolioManager.activePortfolioId {
                                    Text("Current")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        // Under `.buttonStyle(.plain)` only the DRAWN content is hit-testable, so
                        // the gap the Spacer opens up - most of the row - swallowed taps and only
                        // the name itself worked. This makes the whole row the target.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Which portfolio?")
            } footer: {
                Text(summaryLine)
            }
        }
    }

    /// What is about to be recorded, so the choice is made with the transaction in view.
    private var summaryLine: String {
        let direction = candidate.isOutgoing ? "Sent" : "Received"
        return "\(direction) \(PortfolioFormat.kas(candidate.amountKas)) on "
            + candidate.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Step 2

    private var editDetails: some View {
        Form {
            if alreadyInPortfolio {
                Section {
                    Label(
                        "This transaction is already in \(selected?.name ?? "this portfolio"). Adding it again will double-count it.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.orange)
                }
            }

            Section("Type") {
                Picker("Type", selection: $type) {
                    Text("Buy").tag(PortfolioTransactionType.buy)
                    Text("Sell").tag(PortfolioTransactionType.sell)
                }
                .pickerStyle(.segmented)
            }

            Section("Amount and price") {
                LabeledContent("Amount") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Price per KAS") {
                    HStack(spacing: 6) {
                        if isLookingUpPrice { ProgressView().controlSize(.mini) }
                        TextField("0", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let totalValue {
                    LabeledContent("Total") {
                        Text(PortfolioFormat.currency(totalValue, currency))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Date") {
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }

            Section("Note") {
                TextField("Optional", text: $notes, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section {
                Text(candidate.txId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } header: {
                Text("Transaction")
            } footer: {
                // Recording the txid is what lets a later add of the same transaction warn
                // instead of silently double-counting it.
                Text("Recorded with the row, so this transaction is recognised if you add it again.")
            }
        }
    }

    // MARK: - Behaviour

    private func prefill() {
        guard amountText.isEmpty else { return }
        amountText = Self.trimmed(candidate.amountKas)
        // Money leaving the address is a sale, money arriving is a buy. Both are editable: a
        // transfer between your own addresses is neither, and only you know which it was.
        type = candidate.isOutgoing ? .sell : .buy
        date = candidate.timestamp
        selected = portfolioManager.portfolios.first { $0.id == portfolioManager.activePortfolioId }
            ?? portfolioManager.portfolios.first
        lookUpHistoricalPrice()
    }

    /// The price on the day it happened, not today's - a transaction from last year priced at
    /// today's number would silently misstate every figure the portfolio derives from it.
    private func lookUpHistoricalPrice() {
        isLookingUpPrice = true
        let day = candidate.timestamp
        let currency = self.currency
        Task {
            let price = await CoinGeckoService.shared.getHistoricalPrice(date: day, currency: currency)
            await MainActor.run {
                isLookingUpPrice = false
                // Never overwrite something already typed - the lookup can land late.
                guard priceText.isEmpty, let price else { return }
                priceText = Self.trimmed(price, maxDecimals: 6)
            }
        }
    }

    /// Portfolios that already hold this transaction. Same question the ChangeNOW swap chooser
    /// asks, through the same view-model helper, so a duplicate reads the same either way.
    private var duplicatePortfolioIds: Set<UUID> {
        viewModel.portfolioIdsContaining(sourceTxId: candidate.txId)
    }

    private func checkForDuplicate(in portfolio: Portfolio) {
        alreadyInPortfolio = duplicatePortfolioIds.contains(portfolio.id)
    }

    private func confirm() {
        guard let selected, let amount, amount > 0 else { return }
        Haptics.impact(.medium)
        viewModel.addTransaction(
            type: type,
            amountKas: amount,
            fiatValue: totalValue ?? 0,
            timestamp: date,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            portfolioId: selected.id,
            sourceAddress: candidate.address,
            sourceTxId: candidate.txId
        )
        onAdded?(selected)
        dismiss()
    }

    // MARK: - Formatting

    /// Accepts either separator: a decimal keypad emits the device locale's, and reading "1,5" as
    /// an integer would multiply the amount by ten.
    private static func number(from text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    private static func trimmed(_ value: Double, maxDecimals: Int = 8) -> String {
        var text = String(format: "%.\(maxDecimals)f", value)
        while text.hasSuffix("0"), text.split(separator: ".").last?.count ?? 0 > 2 {
            text.removeLast()
        }
        return text
    }
}

/// Brief confirmation that a transaction landed in a portfolio.
///
/// The sheet dismissing is not on its own proof that anything happened - it dismisses on Cancel
/// too - so this says which portfolio got the row, then takes itself away.
struct PortfolioAddedCapsule: View {
    let portfolioName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Added to \(portfolioName)")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
        )
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation { onDismiss() }
        }
    }
}
