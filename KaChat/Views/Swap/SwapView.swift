import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// KAS <-> USDC (Polygon) swaps, powered by ChangeNOW — see SwapService. Structure mirrors
/// Android's SwapScreen (amount cards, flip control, fee editor, swap history) but composed from
/// this app's own glass-card visual language rather than a literal Compose port.
struct SwapView: View {
    @ObservedObject private var swapService = SwapService.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private enum Tab: Int { case swap, history }
    @State private var selectedTab: Tab = .swap

    @State private var selectedSwap: SwapTransaction?
    @State private var showToAddressPicker = false
    @State private var showCoinPicker = false
    @State private var showPortfolioConfirm = false
    @State private var pendingPortfolioPrefill: SwapService.PortfolioPrefill?
    @State private var pendingPortfolioSwapId: String?
    @State private var pendingDeleteSwap: SwapTransaction?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case amount
        case payoutAddress
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                swapTabBar

                TabView(selection: $selectedTab) {
                    swapFormPage
                        .tag(Tab.swap)
                    swapHistoryPage
                        .tag(Tab.history)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Swap")
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
            .onChange(of: swapService.createSwapState.status) { status in
                if status == .success {
                    showToast("Swap started")
                } else if status == .failed {
                    showToast(swapService.createSwapState.errorMessage ?? "Swap failed")
                }
            }
            .sheet(item: $selectedSwap) { swap in
                SwapDetailView(swap: swap) {
                    guard let prefill = swapService.portfolioPrefill(for: swap) else {
                        showToast("Couldn't read this swap's amounts")
                        return
                    }
                    pendingPortfolioPrefill = prefill
                    pendingPortfolioSwapId = swap.id
                    selectedSwap = nil
                    showPortfolioConfirm = true
                }
            }
            .sheet(isPresented: $showToAddressPicker) {
                SwapAddressPickerView { entry in
                    swapService.selectToSpendingAddress(index: entry.index)
                }
            }
            .sheet(isPresented: $showCoinPicker) {
                SwapCoinPickerView(currentCoin: swapService.otherCoin) { coin in
                    swapService.setOtherCoin(coin)
                }
            }
            .confirmationDialog("Add to Portfolio", isPresented: $showPortfolioConfirm, titleVisibility: .visible) {
                // One button per portfolio - the swap lands in the one you pick.
                ForEach(PortfolioManager.shared.portfolios) { portfolio in
                    Button(portfolio.name) {
                        if let prefill = pendingPortfolioPrefill, let swapId = pendingPortfolioSwapId {
                            swapService.confirmAddToPortfolio(prefill, swapId: swapId, portfolioId: portfolio.id)
                            showToast("Added to \(portfolio.name)")
                        }
                        pendingPortfolioPrefill = nil
                        pendingPortfolioSwapId = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingPortfolioPrefill = nil
                    pendingPortfolioSwapId = nil
                }
            } message: {
                if let prefill = pendingPortfolioPrefill {
                    Text("\(prefill.type == .buy ? "Buy" : "Sell") \(formatKas(UInt64((prefill.amountKas * 100_000_000).rounded()))) KAS at \(currencySymbol)\(String(format: "%.2f", prefill.fiatValue)) - choose which portfolio to add it to.")
                }
            }
            .confirmationDialog(
                "Delete this swap?",
                isPresented: Binding(get: { pendingDeleteSwap != nil }, set: { if !$0 { pendingDeleteSwap = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeleteSwap {
                        swapService.deleteSwap(id: pendingDeleteSwap.id)
                    }
                    pendingDeleteSwap = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteSwap = nil
                }
            } message: {
                Text("This only removes it from your local history - it doesn't affect the actual exchange.")
            }
            .overlay {
                if !swapService.swapDisclaimerAgreed {
                    swapDisclaimerOverlay
                }
            }
        }
    }

    // MARK: - Tab bar (same underline style as Broadcasts' Channels/Popular)

    private var swapTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                swapTabButton("Swap", tab: .swap)
                swapTabButton("Swap History", tab: .history)
            }
            Divider()
        }
    }

    private func swapTabButton(_ title: String, tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Swap form

    private var isBusy: Bool {
        swapService.createSwapState.status == .creating
    }

    private var canSwap: Bool {
        swapService.estimateState.status == .success && !isBusy
    }

    private var needsPayoutAddress: Bool {
        swapService.toCoin.ticker != "kas"
    }

    private var swapFormPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                swapAmountCard(
                    label: "You Send",
                    coin: swapService.fromCoin,
                    amountText: swapService.amountText,
                    editable: true,
                    onAmountChange: { swapService.setAmountText($0) },
                    onMaxTap: nil
                )

                HStack(spacing: 12) {
                    Button {
                        swapService.flipDirection()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.black)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch direction"))

                    Button {
                        swapService.executeSwap()
                    } label: {
                        Group {
                            if isBusy {
                                ProgressView().tint(.black)
                            } else {
                                Text(swapButtonTitle)
                                    .fontWeight(.bold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .foregroundColor(canSwap ? .black : .secondary)
                        .background(Capsule().fill(canSwap ? Color.accentColor : Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSwap)
                }

                swapAmountCard(
                    label: "You Get",
                    coin: swapService.toCoin,
                    amountText: estimatedAmountText,
                    editable: false,
                    onAmountChange: { _ in },
                    onMaxTap: nil
                )

                if needsPayoutAddress {
                    TextField("Receive \(swapService.toCoin.displayName) at", text: $swapService.payoutAddressText)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .payoutAddress)
                        .padding(12)
                        .background(glassBackground(cornerRadius: 14))
                }

                if !swapService.kasIsSendSide {
                    spendingAddressRow(
                        title: "Receiving KAS At",
                        valueText: swapService.toAddress.count > 20
                            ? "\(swapService.toAddress.prefix(12))...\(swapService.toAddress.suffix(6))"
                            : swapService.toAddress,
                        feeText: nil,
                        onFeeTap: nil,
                        onChangeTap: { showToAddressPicker = true }
                    )
                }

                rateCard

                if let result = swapService.createSwapState.result {
                    swapResultCard(result)
                }

                Link("Powered by ChangeNOW", destination: URL(string: "https://changenow.io/terms-of-use/changenow-terms")!)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .underline()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var swapButtonTitle: String { "Get Deposit Address" }

    private var estimatedAmountText: String {
        switch swapService.estimateState.status {
        case .success: return formatKasTrimmed(UInt64(((swapService.estimateState.toAmount ?? 0) * 100_000_000).rounded()))
        case .loading: return "..."
        default: return ""
        }
    }

    private var rateCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rate")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(rateText)
                .font(.caption)
                .foregroundColor(swapService.estimateState.status == .failed ? .red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(glassBackground(cornerRadius: 14))
    }

    private var rateText: String {
        if swapService.estimateState.status == .success {
            let fromAmount = Double(swapService.amountText) ?? 0
            let toAmount = swapService.estimateState.toAmount ?? 0
            guard fromAmount > 0 else { return "N/A" }
            let fromLabel = swapService.kasIsSendSide ? "KAS" : swapService.otherCoin.displayName
            let toLabel = swapService.kasIsSendSide ? swapService.otherCoin.displayName : "KAS"
            return "1 \(fromLabel) \u{2248} \(String(format: "%.8f", toAmount / fromAmount)) \(toLabel)"
        } else if swapService.estimateState.status == .failed {
            return swapService.estimateState.errorMessage ?? "Unavailable"
        }
        return "N/A"
    }

    private func swapResultCard(_ result: ChangeNowTransactionResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if swapService.kasIsSendSide {
                NavigationLink {
                    ManageAddressesView()
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Go to Spending Addresses")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .foregroundColor(.accentColor)
                }
                .padding(.bottom, 2)
            }

            Text("Send \(swapService.fromCoin.displayName) to this address")
                .font(.subheadline.weight(.bold))

            if let payinAddress = result.payinAddress {
                HStack {
                    Spacer()
                    if let qrImage = makeQRCodeImage(from: payinAddress) {
                        Button {
                            UIPasteboard.general.string = payinAddress
                            Haptics.success()
                            showToast("Address copied")
                        } label: {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 180)
                                .padding(12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            Button {
                UIPasteboard.general.string = result.payinAddress ?? ""
                Haptics.success()
                showToast("Address copied")
            } label: {
                Text(result.payinAddress ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)

            Text("Status: \(result.status ?? "new")")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("ChangeNOW Exchange ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    UIPasteboard.general.string = result.id
                    Haptics.success()
                    showToast("Exchange ID copied")
                } label: {
                    Text(result.id)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Refresh Status") {
                    swapService.refreshSwapStatus(id: result.id)
                }
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)

                Spacer()

                if let url = URL(string: "https://changenow.io/exchange/txs/\(result.id)") {
                    Link("View on ChangeNOW", destination: url)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Reusable pieces

    private func swapAmountCard(
        label: String,
        coin: SwapCoin,
        amountText: String,
        editable: Bool,
        onAmountChange: @escaping (String) -> Void,
        onMaxTap: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                if editable {
                    TextField("0.00", text: Binding(get: { amountText }, set: onAmountChange))
                        .font(.title2.weight(.semibold))
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .amount)
                    if let onMaxTap {
                        Button("Max", action: onMaxTap)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                } else {
                    Text(amountText.isEmpty ? "0.00" : amountText)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                }
                coinBadge(coin)
            }
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    /// Only the non-KAS side of the pair is actually pickable - KAS is always the fixed side.
    private func coinBadge(_ coin: SwapCoin) -> some View {
        Group {
            if coin.ticker == "kas" {
                coinBadgeContent(coin)
            } else {
                Button {
                    showCoinPicker = true
                } label: {
                    HStack(spacing: 4) {
                        coinBadgeContent(coin)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func coinBadgeContent(_ coin: SwapCoin) -> some View {
        HStack(spacing: 6) {
            swapCoinIcon(coin)
            Text(coin.displayName)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.systemGray5)))
    }

    private func spendingAddressRow(title: String, valueText: String, feeText: String?, onFeeTap: (() -> Void)?, onChangeTap: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(valueText)
                    .font(.caption.weight(.bold))
                if let feeText, let onFeeTap {
                    Button(action: onFeeTap) {
                        Text(feeText)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button("Change", action: onChangeTap)
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
        }
        .padding(12)
        .background(glassBackground(cornerRadius: 14))
    }

    private var swapDisclaimerOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Before You Swap")
                    .font(.headline.weight(.bold))
                Text("Swaps are processed by ChangeNOW, a third-party exchange. By continuing, you confirm you've read and agree to ChangeNOW's own Terms of Service. KaChat only submits your swap request and displays its status; KaChat is not responsible for failed, delayed, or lost swaps. If a swap doesn't go through, contact ChangeNOW support directly.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Not Now") {
                        selectedTab = .swap
                    }
                    .foregroundColor(.secondary)
                    Spacer()
                    Button("I Agree") {
                        swapService.agreeToSwapDisclaimer()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Swap history page

    private var swapHistoryPage: some View {
        Group {
            if swapService.history.isEmpty {
                VStack {
                    Spacer()
                    Text("No swaps yet.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(swapService.history) { swap in
                        HStack(spacing: 8) {
                            Button {
                                selectedSwap = swap
                            } label: {
                                swapHistoryRow(swap)
                            }
                            .buttonStyle(.plain)

                            Button {
                                pendingDeleteSwap = swap
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func swapHistoryRow(_ swap: SwapTransaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(swap.fromAmount) \(swap.fromTicker.uppercased()) \u{2192} \(formatDecimalString(swap.toAmount)) \(swap.toTicker.uppercased())")
                    .font(.subheadline.weight(.bold))
                Text(swap.createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            statusBadge(swap.status)
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Helpers

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
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

    private func formatKas(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func formatKasTrimmed(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private var currencySymbol: String {
        if settingsViewModel.settings.currency == .bitcoin { return "₿" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settingsViewModel.settings.currency.code
        return formatter.currencySymbol ?? settingsViewModel.settings.currency.code
    }

    private func formatDecimalString(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return String(format: "%.8f", value)
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// "Finished"/"Failed"/etc. pill, matching the withdraw/consolidate history rows' orange/green/red
/// status coloring convention used elsewhere in this app.
private func statusBadge(_ status: String) -> some View {
    Text(status.capitalized)
        .font(.caption.weight(.bold))
        .foregroundColor(statusColor(status))
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "finished": return .green
    case "failed", "refunded": return .red
    default: return .orange
    }
}

/// Full detail for one past swap — its deposit QR again, live-ish status, the ChangeNOW exchange
/// id, and a link to track it on changenow.io.
private struct SwapDetailView: View {
    let initialSwap: SwapTransaction
    let onAddToPortfolio: () -> Void

    init(swap: SwapTransaction, onAddToPortfolio: @escaping () -> Void) {
        self.initialSwap = swap
        self.onAddToPortfolio = onAddToPortfolio
    }

    @ObservedObject private var swapService = SwapService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?
    @State private var isRefreshingStatus = false

    /// The LIVE history entry - the sheet used to render the captured value, so Refresh
    /// updated storage but the visible status never changed.
    private var swap: SwapTransaction {
        swapService.history.first { $0.id == initialSwap.id } ?? initialSwap
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(swap.fromAmount) \(swap.fromTicker.uppercased()) \u{2192} \(formatDecimal(swap.toAmount)) \(swap.toTicker.uppercased())")
                            .font(.headline)
                        Text(swap.createdAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Spacer()
                        if let qrImage = makeQRCodeImage(from: swap.payinAddress) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 180, height: 180)
                                .padding(12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Spacer()
                    }
                }

                Section("Deposit Address") {
                    Button {
                        UIPasteboard.general.string = swap.payinAddress
                        Haptics.success()
                        toastMessage = "Address copied"
                    } label: {
                        Text(swap.payinAddress)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                Section("Status") {
                    HStack {
                        Text(swap.status.capitalized)
                            .fontWeight(.bold)
                            .foregroundColor(statusColor(swap.status))
                        Spacer()
                        if swap.status == "finished" {
                            Button("Add to Portfolio", action: onAddToPortfolio)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                Section("ChangeNOW Exchange ID") {
                    Button {
                        UIPasteboard.general.string = swap.id
                        Haptics.success()
                        toastMessage = "Exchange ID copied"
                    } label: {
                        Text(swap.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                Section {
                    Button {
                        guard !isRefreshingStatus else { return }
                        isRefreshingStatus = true
                        Task {
                            let status = await SwapService.shared.refreshSwapStatusAsync(id: swap.id)
                            isRefreshingStatus = false
                            toastMessage = status.map { "Status: \($0.capitalized)" } ?? "Couldn't reach ChangeNOW - try again"
                        }
                    } label: {
                        HStack {
                            Text("Refresh Status")
                                .foregroundColor(.accentColor)
                            Spacer()
                            if isRefreshingStatus {
                                ProgressView()
                                    .scaleEffect(0.85)
                            }
                        }
                    }
                    if let url = URL(string: "https://changenow.io/exchange/txs/\(swap.id)") {
                        Link("View on ChangeNOW", destination: url)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .toast(message: toastMessage)
            .navigationTitle("Swap Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formatDecimal(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return String(format: "%.8f", value)
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Lightweight spending-address picker for Swap's "Change" rows - not the full Manage Addresses
/// screen (this only needs tap-to-pick, no rename/hide/withdraw actions).
private struct SwapAddressPickerView: View {
    let onPick: (SpendingAddressEntry) -> Void

    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button {
                                generateNewAddress()
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Generate New Address")
                                    Spacer()
                                    if isGenerating {
                                        ProgressView()
                                    }
                                }
                                .foregroundColor(.accentColor)
                            }
                            .disabled(isGenerating)
                        }

                        Section {
                            ForEach(entries.filter { !$0.hidden }) { entry in
                                HStack {
                                    Button {
                                        onPick(entry)
                                        dismiss()
                                    } label: {
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
                                                .font(.subheadline.weight(.semibold))
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                                        Menu {
                                            Link(destination: url) {
                                                Label("View in Explorer", systemImage: "safari")
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .foregroundColor(.secondary)
                                        }
                                        .tint(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadEntries()
            }
        }
    }

    private func loadEntries() async {
        isLoading = true
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
    }

    private func generateNewAddress() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            await walletManager.generateNextSpendingAddress()
            await loadEntries()
            isGenerating = false
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Ticker -> `Assets.xcassets` imageset name for coins with real brand art (sourced from the
/// Tangem wallet app's bundled network logos, via its own remote icon CDN -
/// `s3.eu-central-1.amazonaws.com/tangem.api/coins/large/{coingecko-id}.png`). Tickers not listed
/// here have no available art and fall back to the plain ticker-text circle.
private let swapCoinLogoAssetNames: [String: String] = [
    "btc": "CoinBtc",
    "eth": "CoinEth",
    "sol": "CoinSol",
    "xrp": "CoinXrp",
    "bnb": "CoinBnb",
    "trx": "CoinTrx",
    "hype": "CoinHype",
    "doge": "CoinDoge",
    "ltc": "CoinLtc",
    "ada": "CoinAda",
    "bch": "CoinBch",
    "etc": "CoinEtc",
    "usdc": "CoinUsdc",
    "usdt": "CoinUsdt",
    "zec": "CoinZec",
    "xmr": "CoinXmr"
]

/// KAS and the tickers in `swapCoinLogoAssetNames` get their real brand marks; everything else
/// falls back to its ticker in a plain colored circle. Top-level (not a method on `SwapView`) so
/// `SwapCoinPickerView`'s rows can share it too.
@ViewBuilder
func swapCoinIcon(_ coin: SwapCoin) -> some View {
    if coin.ticker == "kas" {
        Image("KaspaLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    } else if let assetName = swapCoinLogoAssetNames[coin.ticker] {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .clipShape(Circle())
    } else {
        Text(coin.ticker.uppercased())
            .font(.system(size: 8, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor.opacity(0.3)))
    }
}

/// Reached by tapping either amount card's coin badge (the non-KAS side only - KAS is always the
/// fixed side of the pair). Searchable since `SwapCoin.curated` now has ~50 entries across many
/// networks, not just the one hardcoded USDC-Polygon pair this originally shipped with.
private struct SwapCoinPickerView: View {
    let currentCoin: SwapCoin
    let onPick: (SwapCoin) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var expandedGroups: Set<String> = []

    /// Tickers with more than one network - collapsed to a single row on the root list that
    /// expands in place to show its networks (rather than listing all ~7-9 networks inline
    /// unconditionally), since that's most of what made the flat list unwieldy. Keyed by ticker,
    /// valued by the short name shown for the collapsed row.
    private static let groupedTickers: [String: String] = [
        "usdt": "Tether",
        "usdc": "USD Coin"
    ]

    private enum PickerRow: Identifiable {
        case coin(SwapCoin)
        case group(ticker: String, displayName: String)
        case network(SwapCoin)

        var id: String {
            switch self {
            case .coin(let coin): return "\(coin.ticker)-\(coin.network)"
            case .group(let ticker, _): return "group-\(ticker)"
            case .network(let coin): return "network-\(coin.ticker)-\(coin.network)"
            }
        }
    }

    /// USDC and USDT are pinned as the first two rows (in that order) since they're the most
    /// commonly swapped stablecoins - everything else follows in `SwapCoin.curated`'s order.
    private static let pinnedGroupTickers = ["usdc", "usdt"]

    private var rootRows: [PickerRow] {
        var rows: [PickerRow] = []
        for ticker in Self.pinnedGroupTickers {
            guard let displayName = Self.groupedTickers[ticker] else { continue }
            rows.append(.group(ticker: ticker, displayName: displayName))
            if expandedGroups.contains(ticker) {
                for coin in SwapCoin.curated where coin.ticker == ticker {
                    rows.append(.network(coin))
                }
            }
        }
        for coin in SwapCoin.curated where Self.groupedTickers[coin.ticker] == nil {
            rows.append(.coin(coin))
        }
        return rows
    }

    private var filteredRows: [PickerRow] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return rootRows }
        let query = searchText.lowercased()
        return rootRows.filter { row in
            switch row {
            case .coin(let coin):
                return coin.displayName.lowercased().contains(query) || coin.ticker.lowercased().contains(query)
            case .group(let ticker, let displayName):
                return displayName.lowercased().contains(query) || ticker.lowercased().contains(query)
            case .network(let coin):
                return coin.displayName.lowercased().contains(query) || coin.ticker.lowercased().contains(query)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredRows) { row in
                switch row {
                case .coin(let coin):
                    Button {
                        onPick(coin)
                        dismiss()
                    } label: {
                        pickerRow(icon: { swapCoinIcon(coin) }, title: coin.displayName, isSelected: coin == currentCoin)
                    }
                    .buttonStyle(.plain)
                case .group(let ticker, let displayName):
                    // Icon only depends on `.ticker`, so any curated entry sharing this ticker
                    // works as the representative icon for the collapsed row.
                    let representative = SwapCoin.curated.first { $0.ticker == ticker }
                    let isExpanded = expandedGroups.contains(ticker)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedGroups.remove(ticker)
                            } else {
                                expandedGroups.insert(ticker)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if let representative {
                                swapCoinIcon(representative)
                            }
                            Text(displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if currentCoin.ticker == ticker {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .network(let coin):
                    Button {
                        onPick(coin)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Spacer().frame(width: 28)
                            swapCoinIcon(coin)
                            Text(coin.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if coin == currentCoin {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search coins")
            .navigationTitle("Choose Coin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pickerRow<Icon: View>(icon: () -> Icon, title: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            icon()
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
