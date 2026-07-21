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
    @State private var showFeeEditor = false
    @State private var feeEditorText = ""
    @State private var showFromAddressPicker = false
    @State private var showToAddressPicker = false
    @State private var showPortfolioConfirm = false
    @State private var pendingPortfolioPrefill: SwapService.PortfolioPrefill?
    @State private var pendingPortfolioSwapId: String?
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
            .navigationBarTitleDisplayMode(.inline)
            .toast(message: toastMessage)
            .task {
                await swapService.refreshSpendingBalance()
            }
            .onChange(of: swapService.createSwapState.status) { status in
                if status == .success {
                    showToast("Swap started")
                } else if status == .failed {
                    showToast(swapService.createSwapState.errorMessage ?? "Swap failed")
                }
            }
            .sheet(item: $selectedSwap) { swap in
                SwapDetailView(swap: swap) {
                    swapService.refreshSwapStatus(id: swap.id)
                } onAddToPortfolio: {
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
            .sheet(isPresented: $showFromAddressPicker) {
                SwapAddressPickerView { entry in
                    swapService.selectFromSpendingAddress(index: entry.index, balanceSompi: entry.balanceSompi)
                }
            }
            .sheet(isPresented: $showToAddressPicker) {
                SwapAddressPickerView { entry in
                    swapService.selectToSpendingAddress(index: entry.index)
                }
            }
            .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
                TextField("Fee (KAS)", text: $feeEditorText)
                    .keyboardType(.decimalPad)
                Button("Save") {
                    if let kas = Double(feeEditorText), kas > 0 {
                        let totalSompi = UInt64((kas * 100_000_000).rounded())
                        swapService.extraFeeSompi = totalSompi > swapService.defaultFeeSompi
                            ? totalSompi - swapService.defaultFeeSompi
                            : 0
                    } else {
                        swapService.extraFeeSompi = 0
                    }
                }
                Button("Use Default") { swapService.extraFeeSompi = 0 }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the network is busy, a higher fee can help your transaction confirm faster.\n\nDefault: \(formatKas(swapService.defaultFeeSompi)) KAS")
            }
            .alert("Add to Portfolio", isPresented: $showPortfolioConfirm) {
                Button("Add") {
                    if let prefill = pendingPortfolioPrefill, let swapId = pendingPortfolioSwapId {
                        swapService.confirmAddToPortfolio(prefill, swapId: swapId)
                        showToast("Added to Portfolio")
                    }
                    pendingPortfolioPrefill = nil
                    pendingPortfolioSwapId = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingPortfolioPrefill = nil
                    pendingPortfolioSwapId = nil
                }
            } message: {
                if let prefill = pendingPortfolioPrefill {
                    Text("\(prefill.type == .buy ? "Buy" : "Sell") \(formatKas(UInt64((prefill.amountKas * 100_000_000).rounded()))) KAS at $\(String(format: "%.2f", prefill.fiatValue)) will be added to your Portfolio ledger.")
                }
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
        swapService.createSwapState.status == .sendingKAS || swapService.createSwapState.status == .creating
    }

    private var amountSompi: UInt64 {
        guard let kas = Double(swapService.amountText) else { return 0 }
        return UInt64((kas * 100_000_000).rounded())
    }

    private var insufficientFunds: Bool {
        swapService.kasIsSendSide && amountSompi > swapService.spendingBalanceSompi
    }

    private var canSwap: Bool {
        swapService.estimateState.status == .success && !isBusy && !insufficientFunds
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
                    onMaxTap: swapService.kasIsSendSide ? {
                        swapService.setAmountText(formatKasTrimmed(swapService.maxSendableSompi))
                    } : nil
                )

                if swapService.kasIsSendSide {
                    spendingAddressRow(
                        title: "Available",
                        valueText: "\(formatKas(swapService.spendingBalanceSompi)) KAS (\(swapService.selectedFromAddress != nil ? "Address #\(swapService.selectedFromAddress!.index)" : "Primary"))",
                        feeText: "Fee: \(formatKas(swapService.effectiveFeeSompi)) KAS",
                        onFeeTap: {
                            feeEditorText = formatKasTrimmed(swapService.effectiveFeeSompi)
                            showFeeEditor = true
                        },
                        onChangeTap: { showFromAddressPicker = true }
                    )
                }

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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
    }

    private var swapButtonTitle: String {
        if insufficientFunds { return "Insufficient Funds" }
        return swapService.kasIsSendSide ? "Swap" : "Get Deposit Address"
    }

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
            Text(swapService.kasIsSendSide ? "KAS sent, exchange in progress" : "Send \(swapService.otherCoin.displayName) to this address")
                .font(.subheadline.weight(.bold))

            if !swapService.kasIsSendSide, let payinAddress = result.payinAddress {
                HStack {
                    Spacer()
                    if let qrImage = makeQRCodeImage(from: payinAddress) {
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

    private func coinBadge(_ coin: SwapCoin) -> some View {
        HStack(spacing: 6) {
            coinIcon(coin)
            Text(coin.displayName)
                .font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.systemGray5)))
    }

    /// KAS and USDC get their real brand marks; anything else falls back to its ticker in a plain badge.
    @ViewBuilder
    private func coinIcon(_ coin: SwapCoin) -> some View {
        if coin.ticker == "kas" {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else if coin.ticker == "usdc" {
            Image("USDCLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Text(coin.ticker.uppercased())
                .font(.caption2.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.3)))
        }
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
                        Button {
                            selectedSwap = swap
                        } label: {
                            swapHistoryRow(swap)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 6)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                swapService.deleteSwap(id: swap.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
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
    let swap: SwapTransaction
    let onRefresh: () -> Void
    let onAddToPortfolio: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?

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
                    Button("Refresh Status", action: onRefresh)
                        .foregroundColor(.accentColor)
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
