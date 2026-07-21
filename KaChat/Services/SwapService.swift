import Foundation

/// KAS <-> USDC (Polygon) swaps, powered by ChangeNOW — combines the roles of Android's
/// SwapViewModel + SwapRepository into one observable service, matching this app's existing
/// pattern of a single `*.shared` service driving Views directly rather than a separate
/// repository layer. For the KAS-is-the-"from"-side case, this sends the KAS itself via
/// ChatService's spending-address send path rather than making the user do that manually in a
/// separate app; the "to" side of a swap is never something this wallet holds, so swapping INTO
/// something other than KAS only ever gets as far as showing the deposit address to pay into.
@MainActor
final class SwapService: ObservableObject {
    static let shared = SwapService()

    private let historyKey = "kachat_swap_history"

    @Published private(set) var history: [SwapTransaction] = []

    // True = KAS is what you're sending (the curated coin is what you receive); false = the
    // reverse. KAS is always one side of the pair, only which side flips.
    @Published var kasIsSendSide: Bool = true
    @Published var otherCoin: SwapCoin = .usdcPolygon
    @Published var amountText: String = ""
    /// Where ChangeNOW should deliver the "to" coin — only asked for when that coin isn't KAS
    /// (KAS always comes back to this wallet automatically).
    @Published var payoutAddressText: String = ""

    struct SelectedFromAddress: Equatable {
        let index: Int
        let address: String
        let balanceSompi: UInt64
    }
    /// Set when the user picked a specific non-primary spending address (via Manage Addresses)
    /// to swap KAS from instead of the active one.
    @Published private(set) var selectedFromAddress: SelectedFromAddress?
    /// KAS available to swap away — the picked address's balance if one was chosen, otherwise
    /// the active spending address's balance. Refreshed explicitly (see `refreshSpendingBalance`)
    /// rather than kept live, matching how the rest of this app reads spending balances.
    @Published private(set) var spendingBalanceSompi: UInt64 = 0

    /// Where swap-received KAS lands. Nil previews the next never-used spending address (same
    /// index math as WalletManager.generateNextSpendingAddress, just not reserved/persisted
    /// until executeSwap actually calls it) - set to a specific index to reuse an existing
    /// address instead, e.g. one already received into from a prior swap.
    @Published private(set) var toAddressOverrideIndex: Int?
    @Published private(set) var toAddress: String = ""

    /// Extra tip on top of the computed default fee, for network congestion - same
    /// default-fee-plus-editable-extra pattern as Manage Addresses' withdraw/consolidate fee
    /// editors, applied to the KAS leg's send when KAS is the "from" side.
    @Published var extraFeeSompi: UInt64 = 0

    enum EstimateStatus { case idle, loading, success, failed }
    struct EstimateUiState {
        var status: EstimateStatus = .idle
        var toAmount: Double?
        var errorMessage: String?
    }
    @Published private(set) var estimateState = EstimateUiState()

    enum CreateSwapStatus { case idle, sendingKAS, creating, success, failed }
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

    // MARK: - Fee (same reference-mass shortcut as Cold Storage/Manage Addresses fee editors)

    var referenceMass: UInt64 { ColdStorageSendEngine.referenceMassForFeeEditor }

    var defaultFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: KaspaFeePolicy.minimumRelayFeePerGramSompi)
    }

    var effectiveFeeSompi: UInt64 {
        defaultFeeSompi + extraFeeSompi
    }

    /// Full balance minus the estimated fee, no change output - same shortcut as the withdraw
    /// dialogs' Max button.
    var maxSendableSompi: UInt64 {
        let fee = effectiveFeeSompi
        return spendingBalanceSompi > fee ? spendingBalanceSompi - fee : 0
    }

    // MARK: - Coin selection / direction

    var fromCoin: SwapCoin { kasIsSendSide ? .kas : otherCoin }
    var toCoin: SwapCoin { kasIsSendSide ? otherCoin : .kas }

    func flipDirection() {
        kasIsSendSide.toggle()
        rescheduleEstimate()
    }

    func setOtherCoin(_ coin: SwapCoin) {
        otherCoin = coin
        rescheduleEstimate()
    }

    func setAmountText(_ text: String) {
        amountText = text
        rescheduleEstimate()
    }

    // MARK: - From/to spending address selection

    func selectFromSpendingAddress(index: Int, balanceSompi: UInt64) {
        guard let address = WalletManager.shared.spendingAddress(at: index) else { return }
        selectedFromAddress = SelectedFromAddress(index: index, address: address, balanceSompi: balanceSompi)
        Task { await refreshSpendingBalance() }
    }

    func clearSelectedFromSpendingAddress() {
        selectedFromAddress = nil
        Task { await refreshSpendingBalance() }
    }

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

    func refreshSpendingBalance() async {
        if let selected = selectedFromAddress {
            spendingBalanceSompi = selected.balanceSompi
            return
        }
        guard let address = WalletManager.shared.currentSpendingAddress() else {
            spendingBalanceSompi = 0
            return
        }
        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
        spendingBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
    }

    // MARK: - Live quote

    /// Debounced live quote — re-fires on every relevant field change rather than needing an
    /// explicit "Get Rate" tap.
    private func rescheduleEstimate() {
        estimateTask?.cancel()
        guard let amount = Double(amountText), amount > 0 else {
            estimateState = EstimateUiState()
            return
        }
        let from = fromCoin
        let to = toCoin
        let amountStr = amountText
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            estimateState = EstimateUiState(status: .loading)
            do {
                let response = try await ChangeNowAPIClient.shared.getEstimatedAmount(
                    fromCurrency: from.ticker,
                    fromNetwork: from.network,
                    toCurrency: to.ticker,
                    toNetwork: to.network,
                    fromAmount: amountStr
                )
                guard !Task.isCancelled else { return }
                estimateState = EstimateUiState(status: .success, toAmount: response.toAmount)
            } catch {
                guard !Task.isCancelled else { return }
                estimateState = EstimateUiState(status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    // MARK: - Execute swap

    func executeSwap() {
        guard let amount = Double(amountText), amount > 0 else { return }
        let from = fromCoin
        let to = toCoin
        let amountStr = amountText

        createSwapState = CreateSwapUiState(status: from.ticker == "kas" ? .sendingKAS : .creating)

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

                var kasSendTxId: String?
                if from.ticker == "kas" {
                    let amountSompi = UInt64((amount * 100_000_000).rounded())
                    let fromIndex = selectedFromAddress?.index ?? WalletManager.shared.currentSpendingAddressIndex
                    do {
                        kasSendTxId = try await ChatService.shared.sendFromSpendingAddress(
                            index: fromIndex,
                            toAddress: payinAddress,
                            amountSompi: amountSompi,
                            extraFeeSompi: extraFeeSompi
                        )
                    } catch {
                        createSwapState = CreateSwapUiState(status: .failed, errorMessage: error.localizedDescription)
                        return
                    }
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
                    kasSendTxId: kasSendTxId
                )
                history.insert(transaction, at: 0)
                saveHistory()

                createSwapState = CreateSwapUiState(status: .success, result: response)
                amountText = ""
                estimateState = EstimateUiState()
                selectedFromAddress = nil
                toAddressOverrideIndex = nil
                extraFeeSompi = 0
                await refreshSpendingBalance()
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
        Task {
            guard let response = try? await ChangeNowAPIClient.shared.getTransactionStatus(id: id),
                  let status = response.status else { return }
            if let index = history.firstIndex(where: { $0.id == id }) {
                history[index].status = status
                saveHistory()
            }
        }
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

    func confirmAddToPortfolio(_ prefill: PortfolioPrefill, swapId: String) {
        // Goes through the shared view model (not a direct PortfolioLedgerStore write) so
        // Portfolio's own @Published transactions list picks this up immediately if it's already
        // open, instead of only reflecting it after the app is relaunched.
        PortfolioViewModel.shared.addTransaction(
            type: prefill.type,
            amountKas: prefill.amountKas,
            fiatValue: prefill.fiatValue,
            timestamp: prefill.timestamp,
            notes: prefill.notes
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
