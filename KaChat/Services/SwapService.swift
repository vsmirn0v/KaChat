import Foundation

/// KAS <-> USDC (Polygon) swaps, powered by ChangeNOW — combines the roles of Android's
/// SwapViewModel + SwapRepository into one observable service, matching this app's existing
/// pattern of a single `*.shared` service driving Views directly rather than a separate
/// repository layer. Neither side of a swap is something this app sends automatically: whichever
/// coin the user is giving up, they pay into the ChangeNOW deposit address themselves (shown as a
/// QR code), same as the "to" side already worked when that coin wasn't KAS.
@MainActor
final class SwapService: ObservableObject {
    static let shared = SwapService()

    private let historyKey = "kachat_swap_history"

    @Published private(set) var history: [SwapTransaction] = []

    // True = KAS is what you're sending (the curated coin is what you receive); false = the
    // reverse. KAS is always one side of the pair, only which side flips. Defaults to false -
    // most people opening Swap are looking to acquire KAS, not sell it, so "You Send" starts on
    // the other coin and "You Get" starts on KAS.
    @Published var kasIsSendSide: Bool = false
    @Published var otherCoin: SwapCoin = .usdcPolygon
    /// The "You Send" amount. Typed by the user when `editedSide == .send`; otherwise filled in
    /// by the reverse quote for whatever they typed under "You Get".
    @Published var amountText: String = ""
    /// The "You Get" amount - the mirror of `amountText`: typed when `editedSide == .get`, else
    /// the direct quote's answer.
    @Published var receiveAmountText: String = ""

    /// Which amount the user last typed. The other one is a quote and gets overwritten by every
    /// estimate; the typed one is the input the swap is created from.
    enum AmountSide { case send, get }
    @Published private(set) var editedSide: AmountSide = .send
    /// Where ChangeNOW should deliver the "to" coin — only asked for when that coin isn't KAS
    /// (KAS always comes back to this wallet automatically).
    @Published var payoutAddressText: String = ""

    /// Where swap-received KAS lands. Nil previews the next never-used spending address (same
    /// index math as WalletManager.generateNextSpendingAddress, just not reserved/persisted
    /// until executeSwap actually calls it) - set to a specific index to reuse an existing
    /// address instead, e.g. one already received into from a prior swap.
    @Published private(set) var toAddressOverrideIndex: Int?
    @Published private(set) var toAddress: String = ""

    enum EstimateStatus { case idle, loading, success, failed }
    struct EstimateUiState {
        var status: EstimateStatus = .idle
        /// Both sides of the quote once it succeeds - the typed one echoed back, the other one
        /// ChangeNOW's answer.
        var fromAmount: Double?
        var toAmount: Double?
        var errorMessage: String?
    }
    @Published private(set) var estimateState = EstimateUiState()

    enum CreateSwapStatus { case idle, creating, success, failed }
    struct CreateSwapUiState {
        var status: CreateSwapStatus = .idle
        var result: ChangeNowTransactionResponse?
        var errorMessage: String?
    }
    @Published private(set) var createSwapState = CreateSwapUiState()

    private var estimateTask: Task<Void, Never>?

    private init() {
        history = Self.loadHistory()
        refreshToAddress()
    }

    // MARK: - Coin selection / direction

    var fromCoin: SwapCoin { kasIsSendSide ? .kas : otherCoin }
    var toCoin: SwapCoin { kasIsSendSide ? otherCoin : .kas }

    func flipDirection() {
        kasIsSendSide.toggle()
        clearQuotedAmount()
        rescheduleEstimate()
    }

    func setOtherCoin(_ coin: SwapCoin) {
        otherCoin = coin
        clearQuotedAmount()
        rescheduleEstimate()
    }

    /// The pair changed, so the quoted side's figure is for a different pair - blank it until
    /// the new quote lands; the typed side stays as the input.
    private func clearQuotedAmount() {
        switch editedSide {
        case .send: receiveAmountText = ""
        case .get: amountText = ""
        }
    }

    /// "You Send" typed: the "You Get" figure is now stale, so it clears until the quote lands.
    func setAmountText(_ text: String) {
        amountText = text
        editedSide = .send
        receiveAmountText = ""
        rescheduleEstimate()
    }

    /// "You Get" typed: the reverse quote will fill "You Send" with what that costs.
    func setReceiveAmountText(_ text: String) {
        receiveAmountText = text
        editedSide = .get
        amountText = ""
        rescheduleEstimate()
    }

    /// The amount the user typed, whichever card it was.
    private var editedAmountText: String {
        editedSide == .send ? amountText : receiveAmountText
    }

    /// Plain decimal text for a quoted amount: up to 8 places, trailing zeros trimmed, never
    /// scientific notation - it is shown in the card and, for a reverse quote, sent back to
    /// ChangeNOW as the `fromAmount` the exchange is created with.
    static func formatQuotedAmount(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - To spending address selection

    func selectToSpendingAddress(index: Int) {
        toAddressOverrideIndex = index
        refreshToAddress()
    }

    func clearToSpendingAddressOverride() {
        toAddressOverrideIndex = nil
        refreshToAddress()
    }

    private func nextFreshSpendingIndex() -> Int {
        max(WalletManager.shared.maxSpendingAddressIndex, WalletManager.shared.currentSpendingAddressIndex) + 1
    }

    func refreshToAddress() {
        let index = toAddressOverrideIndex ?? nextFreshSpendingIndex()
        toAddress = WalletManager.shared.spendingAddress(at: index) ?? ""
    }

    // MARK: - Live quote

    /// Debounced live quote — re-fires on every relevant field change rather than needing an
    /// explicit "Get Rate" tap.
    private func rescheduleEstimate() {
        estimateTask?.cancel()
        guard let amount = Double(editedAmountText), amount > 0 else {
            estimateState = EstimateUiState()
            return
        }
        let from = fromCoin
        let to = toCoin
        let side = editedSide
        let amountStr = editedAmountText
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            estimateState = EstimateUiState(status: .loading)
            do {
                // Direct quote answers "You Get" for a typed "You Send"; the reverse quote
                // answers "You Send" for a typed "You Get". Either way the quoted side's card
                // is filled from the response so both figures are ChangeNOW's, not ours.
                let response: ChangeNowEstimateResponse
                switch side {
                case .send:
                    response = try await ChangeNowAPIClient.shared.getEstimatedAmount(
                        fromCurrency: from.ticker,
                        fromNetwork: from.network,
                        toCurrency: to.ticker,
                        toNetwork: to.network,
                        fromAmount: amountStr
                    )
                case .get:
                    response = try await ChangeNowAPIClient.shared.getReverseEstimatedAmount(
                        fromCurrency: from.ticker,
                        fromNetwork: from.network,
                        toCurrency: to.ticker,
                        toNetwork: to.network,
                        toAmount: amountStr
                    )
                }
                guard !Task.isCancelled else { return }
                switch side {
                case .send: receiveAmountText = Self.formatQuotedAmount(response.toAmount)
                case .get: amountText = Self.formatQuotedAmount(response.fromAmount)
                }
                estimateState = EstimateUiState(
                    status: .success,
                    fromAmount: response.fromAmount,
                    toAmount: response.toAmount
                )
            } catch {
                guard !Task.isCancelled else { return }
                estimateState = EstimateUiState(status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    // MARK: - Execute swap

    func executeSwap() {
        // `amountText` is either what the user typed under "You Send" or the reverse quote's
        // answer for what they typed under "You Get" - the exchange is always created from
        // the send amount, so a "You Get" target rides on the standard flow: the deposit is
        // the quoted figure and the payout floats with the rate, as with any typed send.
        guard let amount = Double(amountText), amount > 0 else { return }
        let from = fromCoin
        let to = toCoin
        let amountStr = amountText

        createSwapState = CreateSwapUiState(status: .creating)

        Task {
            let payoutAddress: String
            // Swapping into KAS lands in a fresh, never-used spending address by default (rather
            // than the active one, so exchange-received coins can't be chain-linked to everyday
            // spending out of this wallet) unless the user explicitly picked a different address
            // to reuse. Swapping out of KAS needs somewhere else to send the other coin, since
            // this wallet doesn't hold it.
            if to.ticker == "kas" {
                if let overrideIndex = toAddressOverrideIndex {
                    payoutAddress = WalletManager.shared.spendingAddress(at: overrideIndex) ?? ""
                } else {
                    await WalletManager.shared.generateNextSpendingAddress()
                    let freshIndex = WalletManager.shared.maxSpendingAddressIndex
                    payoutAddress = WalletManager.shared.spendingAddress(at: freshIndex) ?? ""
                }
            } else {
                payoutAddress = payoutAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !payoutAddress.isEmpty else {
                createSwapState = CreateSwapUiState(
                    status: .failed,
                    errorMessage: "Enter an address to receive the \(to.displayName)"
                )
                return
            }

            do {
                let response = try await ChangeNowAPIClient.shared.createTransaction(
                    fromCurrency: from.ticker,
                    fromNetwork: from.network,
                    toCurrency: to.ticker,
                    toNetwork: to.network,
                    fromAmount: amountStr,
                    address: payoutAddress
                )
                guard let payinAddress = response.payinAddress, !payinAddress.isEmpty else {
                    createSwapState = CreateSwapUiState(status: .failed, errorMessage: "ChangeNOW didn't return a deposit address")
                    return
                }

                let transaction = SwapTransaction(
                    id: response.id,
                    fromTicker: from.ticker,
                    fromNetwork: from.network,
                    toTicker: to.ticker,
                    toNetwork: to.network,
                    fromAmount: amountStr,
                    toAmount: response.toAmount.map { String($0) } ?? "",
                    payinAddress: payinAddress,
                    payoutAddress: payoutAddress,
                    status: response.status ?? "new",
                    createdAt: Date(),
                    kasSendTxId: nil
                )
                history.insert(transaction, at: 0)
                saveHistory()

                createSwapState = CreateSwapUiState(status: .success, result: response)
                amountText = ""
                receiveAmountText = ""
                editedSide = .send
                estimateState = EstimateUiState()
                toAddressOverrideIndex = nil
                refreshToAddress()
            } catch {
                createSwapState = CreateSwapUiState(status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    func resetCreateSwapState() {
        createSwapState = CreateSwapUiState()
    }

    func refreshSwapStatus(id: String) {
        Task { _ = await refreshSwapStatusAsync(id: id) }
    }

    /// Awaitable variant for the detail screen's Refresh button: returns the fresh status on
    /// success (history is updated + published either way) so the UI can give real feedback.
    func refreshSwapStatusAsync(id: String) async -> String? {
        guard let response = try? await ChangeNowAPIClient.shared.getTransactionStatus(id: id),
              let status = response.status else { return nil }
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].status = status
            saveHistory()
        }
        return status
    }

    func deleteSwap(id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    // MARK: - Add to Portfolio

    struct PortfolioPrefill {
        let type: PortfolioTransactionType
        let amountKas: Double
        let fiatValue: Double
        let timestamp: Date
        let notes: String
    }

    /// Computes what a "finished" swap would add to the Portfolio ledger, for the caller to
    /// show a confirmation before actually saving (see `confirmAddToPortfolio`) - this app
    /// doesn't have Android's prefilled-add-transaction-screen navigation flow, so a lightweight
    /// confirm-then-save replaces it instead.
    func portfolioPrefill(for swap: SwapTransaction) -> PortfolioPrefill? {
        let isKasReceived = swap.toTicker == "kas"
        guard let amountKas = Double(isKasReceived ? swap.toAmount : swap.fromAmount),
              let fiatValue = Double(isKasReceived ? swap.fromAmount : swap.toAmount) else {
            return nil
        }
        return PortfolioPrefill(
            type: isKasReceived ? .buy : .sell,
            amountKas: amountKas,
            fiatValue: fiatValue,
            timestamp: swap.createdAt,
            notes: "ChangeNOW swap \(swap.id)"
        )
    }

    func confirmAddToPortfolio(_ prefill: PortfolioPrefill, swapId: String, portfolioId: UUID? = nil) {
        // Goes through the shared view model (not a direct PortfolioLedgerStore write) so
        // Portfolio's own @Published transactions list picks this up immediately if it's already
        // open, instead of only reflecting it after the app is relaunched.
        PortfolioViewModel.shared.addTransaction(
            type: prefill.type,
            amountKas: prefill.amountKas,
            fiatValue: prefill.fiatValue,
            timestamp: prefill.timestamp,
            notes: prefill.notes,
            portfolioId: portfolioId,
            // Namespaced so it can never collide with a Kaspa txid. Without this a swap had no
            // provenance at all and could be added to the same portfolio over and over.
            sourceTxId: PortfolioViewModel.swapSourceTxId(swapId)
        )

        if let index = history.firstIndex(where: { $0.id == swapId }) {
            history[index].addedToPortfolio = true
            saveHistory()
        }
    }

    // MARK: - Disclaimer

    var swapDisclaimerAgreed: Bool {
        AppSettings.load().swapDisclaimerAgreed
    }

    func agreeToSwapDisclaimer() {
        var settings = AppSettings.load()
        settings.swapDisclaimerAgreed = true
        AppSettings.save(settings)
        objectWillChange.send()
    }

    // MARK: - History persistence

    private static func loadHistory() -> [SwapTransaction] {
        guard let data = UserDefaults.standard.data(forKey: "kachat_swap_history"),
              let decoded = try? JSONDecoder().decode([SwapTransaction].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveHistory() {
        history.sort { $0.createdAt > $1.createdAt }
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
