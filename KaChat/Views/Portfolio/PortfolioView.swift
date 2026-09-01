import SwiftUI
import Charts

struct PortfolioView: View {
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @ObservedObject private var portfolioManager = PortfolioManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var networkStats = KaspaNetworkStatsService.shared
    @State private var showPriceChart = false
    @State private var showHashrateChart = false
    @State private var showValueChart = false

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    var body: some View {
        NavigationStack {
            // One continuous page: portfolio picker cards, then the two launcher squares, then the
            // Transactions section - no Data/Transactions tabs. Everything lives in the
            // transactions view's List, so scrolling flows straight from cards into
            // transactions, the picker cards scroll away (collapse) cleanly, and the large
            // nav title tracks the scroll natively.
            PortfolioTransactionsView(viewModel: viewModel) {
                Section {
                    PortfolioPickerHeader(
                        portfolios: portfolioManager.portfolios,
                        activePortfolioId: portfolioManager.activePortfolioId,
                        cardModel: cardModel(for:),
                        formatCurrency: { PortfolioFormat.currency($0, currency) },
                        onSelect: { portfolioManager.setActivePortfolio($0) },
                        onAdd: { portfolioManager.addPortfolio(name: $0) },
                        onRename: { portfolioManager.renamePortfolio($0, to: $1) },
                        onDelete: { portfolioManager.deletePortfolio($0) },
                        onReorder: { portfolioManager.reorderPortfolios($0) }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    // Two tappable squares: KAS price (left) and portfolio value (right). Each
                    // opens its own full-screen chart screen. The old inline price/value
                    // sparkline sliders were removed - those views now live behind these squares.
                    launcherSquares
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    // Network hashrate, full width under the squares: it is one series with a long
                    // history, so it reads far better wide than squeezed into a third square.
                    hashrateCard
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
        }
    }

    private func cardModel(for portfolio: Portfolio) -> PortfolioCardModel {
        let change = viewModel.todayChange(for: portfolio.id)
        return PortfolioCardModel(
            id: portfolio.id,
            name: portfolio.name,
            currentValue: viewModel.currentValue(for: portfolio.id),
            todayChangeAmount: change?.amount,
            todayChangePercent: change?.percent
        )
    }

    // MARK: - Launcher squares

    private var launcherSquares: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.impact(.light)
                showPriceChart = true
            } label: {
                priceSquare
            }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $showPriceChart) {
                KasPriceChartScreen(viewModel: viewModel)
            }

            Button {
                Haptics.impact(.light)
                showValueChart = true
            } label: {
                valueSquare
            }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $showValueChart) {
                PortfolioValueChartScreen(viewModel: viewModel)
            }
        }
    }

    private var hashrateCard: some View {
        Button {
            Haptics.impact(.light)
            showHashrateChart = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network Hashrate")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text(networkStats.currentHashrate.map(HashrateFormat.display) ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                // A sparkline of the recent window, so the card says which way it is going
                // without the user having to open it.
                if networkStats.hashrateHistory.count >= 2 {
                    PortfolioSparkline(points: Array(networkStats.hashrateHistory.suffix(90)))
                        .frame(width: 96, height: 34)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(portfolioGlassBackground(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $showHashrateChart) {
            HashrateChartScreen()
        }
        .task { await networkStats.refreshIfNeeded() }
    }

    private var priceSquare: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("KaspaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Kaspa")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(viewModel.currentPriceUsd.map { PortfolioFormat.price($0, currency: currency) } ?? "—")
                .font(.system(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let change = viewModel.priceChange24h {
                changeBadge(percent: change, positive: change >= 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private var valueSquare: some View {
        let summary = viewModel.summary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Value")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(PortfolioFormat.currency(summary.currentValue, currency))
                .font(.system(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            changeBadge(percent: summary.totalPLPercent, positive: summary.totalPL >= 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private func changeBadge(percent: Double, positive: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: positive ? "arrow.up" : "arrow.down").font(.caption2)
            Text("\(String(format: "%.2f", abs(percent)))%")
                .font(.footnote).fontWeight(.semibold)
        }
        .foregroundColor(positive ? .green : .red)
    }
}

// MARK: - KAS price full-screen chart

private struct KasPriceChartScreen: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var scrubbed: PricePoint?

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                chart
                PortfolioRangePicker(viewModel: viewModel, onChange: { scrubbed = nil })
                KasConverterCard(priceUsd: viewModel.currentPriceUsd, currency: currency)
            }
            .padding(16)
        }
        .refreshable { await viewModel.refreshPriceAsync() }
        .navigationTitle("KAS Price")
        .navigationBarTitleDisplayMode(.inline)
    }

    // The Kaspa logo + name stay put while scrubbing - only the date + scrubbed price change.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("KaspaLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                Text("Kaspa").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().year().hour().minute())
                    .font(.subheadline).foregroundColor(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((scrubbed?.value ?? viewModel.currentPriceUsd).map { PortfolioFormat.price($0, currency: currency) } ?? "—")
                    .font(.system(size: 34, weight: .bold))
                if scrubbed == nil, let change = viewModel.priceChange24h {
                    HStack(spacing: 3) {
                        Image(systemName: change >= 0 ? "arrow.up" : "arrow.down").font(.footnote)
                        Text("\(String(format: "%.2f", abs(change)))% (24h)")
                            .font(.subheadline).fontWeight(.semibold)
                    }
                    .foregroundColor(change >= 0 ? .green : .red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var chart: some View {
        if viewModel.priceHistory.count >= 2 {
            PortfolioAreaChart(points: viewModel.priceHistory, onScrub: { scrubbed = $0 })
                .frame(height: 260)
        } else {
            ProgressView()
                .frame(height: 260)
                .frame(maxWidth: .infinity)
        }
    }

}

// MARK: - Portfolio value full-screen chart + stats

private struct PortfolioValueChartScreen: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var scrubbed: PricePoint?

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    var body: some View {
        let summary = viewModel.summary
        let history = viewModel.valueHistory

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(currentValue: summary.currentValue)

                if history.count >= 2 {
                    PortfolioAreaChart(points: history, onScrub: { scrubbed = $0 })
                        .frame(height: 240)
                } else {
                    Text("Not enough history yet - check back after a few days of activity.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                }

                PortfolioRangePicker(viewModel: viewModel, onChange: { scrubbed = nil })

                statsCard(summary)
            }
            .padding(16)
        }
        .refreshable { await viewModel.refreshPriceAsync() }
        .navigationTitle("Value Over Time")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(currentValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Portfolio Value").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().year())
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Text(PortfolioFormat.currency(scrubbed?.value ?? currentValue, currency))
                .font(.system(size: 34, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statsCard(_ summary: PortfolioSummary) -> some View {
        VStack(spacing: 0) {
            statRow("Holdings", PortfolioFormat.kas(summary.holdingsKas))
            Divider()
            statRow("Current Value", PortfolioFormat.currency(summary.currentValue, currency))
            Divider()
            statRow("Total Invested", PortfolioFormat.currency(summary.totalInvested, currency))
            Divider()
            statRow(
                "Total P&L",
                "\(PortfolioFormat.currency(summary.totalPL, currency)) (\(String(format: "%.1f", summary.totalPLPercent))%)",
                color: summary.totalPL >= 0 ? .green : .red
            )
            if let averageBuyPriceUsd = summary.averageBuyPriceUsd {
                Divider()
                statRow("Avg. Buy Price", PortfolioFormat.price(averageBuyPriceUsd, currency: currency))
            }
        }
        .padding(.vertical, 4)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private func statRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.body).fontWeight(.semibold).foregroundColor(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Shared range picker (1D / 1W / 1M / 3M / 1Y)

/// Drives `PortfolioViewModel.priceRangeDays`, which both the KAS price history AND the derived
/// portfolio value-over-time series read from, so this one control ranges both charts.
private struct PortfolioRangePicker: View {
    @ObservedObject var viewModel: PortfolioViewModel
    var onChange: () -> Void = {}

    private let ranges: [(label: String, days: Int)] = [("1D", 1), ("1W", 7), ("1M", 30), ("3M", 90), ("1Y", 365)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ranges, id: \.days) { range in
                Button {
                    Haptics.impact(.light)
                    onChange()
                    viewModel.setPriceRangeDays(range.days)
                } label: {
                    Text(range.label)
                        .font(.subheadline).fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(viewModel.priceRangeDays == range.days ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(viewModel.priceRangeDays == range.days ? .accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared formatting + styling

/// Currency/price/KAS formatting shared by the portfolio squares and both chart screens. Built
/// manually via `currencySymbol(for:)` rather than `.formatted(.currency(code:))` - the latter is
/// Foundation's ISO-4217-driven `FormatStyle`, whose behavior for a non-ISO-4217 code like
/// `.bitcoin`'s "BTC" isn't something to rely on sight-unseen.
enum PortfolioFormat {
    static func currencySymbol(for currency: AppCurrency) -> String {
        if currency == .bitcoin { return "₿" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        return formatter.currencySymbol ?? currency.code
    }

    static func price(_ value: Double, currency: AppCurrency) -> String {
        let decimals = value < 1 ? 5 : 2
        return currencySymbol(for: currency) + String(format: "%.\(decimals)f", value)
    }

    static func currency(_ value: Double, _ currency: AppCurrency) -> String {
        let sign = value < 0 ? "-" : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return sign + currencySymbol(for: currency) + magnitude
    }

    private static let kasFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func kas(_ value: Double) -> String {
        let text = kasFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        return text + " KAS"
    }
}

private func portfolioGlassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

// MARK: - Chart

/// Swift Charts area+line chart with gridlines/axes and drag-to-scrub. Replaces the old bare
/// sparkline so the full-screen views read like a real price/value graph. `onScrub` fires the
/// nearest point (or nil on release) so the screen's header can show the selected value/date.
private struct PortfolioAreaChart: View {
    let points: [PricePoint]
    var onScrub: ((PricePoint?) -> Void)?

    @State private var selected: PricePoint?

    var body: some View {
        let values = points.map(\.value)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let span = (maxV - minV) > 0 ? (maxV - minV) : max(abs(maxV), 1)
        let pad = span * 0.10
        let lowerBound = minV - pad
        let upperBound = maxV + pad

        // For a short (intraday, e.g. 1D) span, default date+time labels are wide and collide.
        // Format those as hours ("3 PM") and longer spans as dates ("Mar 5") so labels stay short.
        let timeSpan = (points.last?.timestamp ?? Date()).timeIntervalSince(points.first?.timestamp ?? Date())
        let isIntraday = timeSpan <= 2 * 24 * 60 * 60

        Chart {
            ForEach(points, id: \.timestamp) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    yStart: .value("Min", lowerBound),
                    yEnd: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if let selected {
                RuleMark(x: .value("Time", selected.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", selected.timestamp), y: .value("Value", selected.value))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(120)
            }
        }
        .chartYScale(domain: lowerBound...upperBound)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: isIntraday
                    ? Date.FormatStyle().hour()
                    : Date.FormatStyle().month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plot = geo[proxy.plotAreaFrame]
                                let xInPlot = value.location.x - plot.minX
                                guard xInPlot >= 0, xInPlot <= plot.width,
                                      let date: Date = proxy.value(atX: xInPlot) else { return }
                                let nearest = points.min(by: {
                                    abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
                                })
                                if selected?.timestamp != nearest?.timestamp {
                                    selected = nearest
                                    onScrub?(nearest)
                                }
                            }
                            .onEnded { _ in
                                selected = nil
                                onScrub?(nil)
                            }
                    )
            }
        }
    }
}

// MARK: - KAS <-> fiat converter

/// Two-way converter, in the slot the static "About Kaspa" blurb used to hold.
///
/// The blurb was read once and never again; a converter is the thing people actually reach for on
/// a price screen. It uses the SELECTED currency, so it answers the question in the units the rest
/// of the portfolio is already denominated in.
private struct KasConverterCard: View {
    let priceUsd: Double?
    let currency: AppCurrency

    /// Which field the user is typing in. The other is derived, so only one is ever authoritative
    /// and a rounded value can never be fed back through the rate and drift.
    private enum Field { case kas, fiat }

    @State private var kasText = "1"
    @State private var fiatText = ""
    @State private var editing: Field = .kas
    @FocusState private var focused: Field?

    /// Price in the SELECTED currency. `currentPriceUsd` is already converted upstream (it is what
    /// every other figure on this screen is drawn from), so this is a rename, not a conversion.
    private var rate: Double? {
        guard let priceUsd, priceUsd > 0 else { return nil }
        return priceUsd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Converter")
                .font(.headline)

            row(
                title: "KAS",
                text: $kasText,
                field: .kas,
                trailing: "KAS"
            )
            row(
                title: currency.code,
                text: $fiatText,
                field: .fiat,
                trailing: PortfolioFormat.currencySymbol(for: currency)
            )

            if let rate {
                // Not PortfolioFormat.price: that rounds to 5 decimals under a dollar, which
                // for a sub-cent coin throws away most of the rate the converter is applying.
                Text("1 KAS = \(PortfolioFormat.currencySymbol(for: currency))\(Self.format(rate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for a price...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
        .onAppear { recompute(from: .kas) }
        // A price refresh, or switching currency, has to move the derived side.
        .onChange(of: priceUsd) { _ in recompute(from: editing) }
        .onChange(of: currency) { _ in recompute(from: editing) }
    }

    private func row(title: String, text: Binding<String>, field: Field, trailing: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 20, weight: .semibold))
                .focused($focused, equals: field)
                .onChange(of: text.wrappedValue) { _ in
                    // Only the focused field drives; without this the derived write would bounce
                    // straight back and the two would fight each other keystroke for keystroke.
                    guard focused == field else { return }
                    editing = field
                    recompute(from: field)
                }
            Text(trailing)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Writes the OTHER field from the one being edited.
    private func recompute(from field: Field) {
        guard let rate else { return }
        switch field {
        case .kas:
            let kas = Self.number(from: kasText)
            fiatText = kas.map { Self.format($0 * rate) } ?? ""
        case .fiat:
            let fiat = Self.number(from: fiatText)
            kasText = fiat.map { Self.format($0 / rate) } ?? ""
        }
    }

    /// Accepts either separator: a decimal keypad emits the device locale's, which is a comma in
    /// much of the world, and parsing that as an integer silently multiplied the amount.
    private static func number(from text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    /// Full precision, with the padding trimmed off.
    ///
    /// Fixed decimals do not work in either direction here: two decimals on the fiat side rounds
    /// 1 KAS to "0.05" and throws the rate away, and four on the KAS side is coarser than the
    /// eight sompi actually carries. So this writes eight decimals - Kaspa's own precision - and
    /// then drops the trailing zeros, keeping two so a whole amount still reads as money.
    ///
    /// Deliberately locale-free: the result is written straight back into a text field the user
    /// can keep editing, and a grouping separator would make it unparseable on the way back in.
    private static func format(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0"), text.split(separator: ".").last?.count ?? 0 > 2 {
            text.removeLast()
        }
        return text
    }
}

// MARK: - Network hashrate

/// A tiny line, no axes or labels - just the shape of the recent window.
private struct PortfolioSparkline: View {
    let points: [PricePoint]

    var body: some View {
        GeometryReader { geo in
            let values = points.map(\.value)
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(maxV - minV, .leastNonzeroMagnitude)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = geo.size.width * (points.count > 1 ? CGFloat(index) / CGFloat(points.count - 1) : 0)
                    let y = geo.size.height * (1 - CGFloat((point.value - minV) / span))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The full hashrate history, with the same range control the price and value charts use.
private struct HashrateChartScreen: View {
    @ObservedObject private var networkStats = KaspaNetworkStatsService.shared
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @State private var scrubbed: PricePoint?
    @State private var rangeDays: Int = 90

    /// "All" is a real option here in a way it is not for price: the series starts at effectively
    /// zero in 2021 and the whole shape of the network's growth is the interesting part.
    private static let ranges: [(label: String, days: Int)] = [
        ("1M", 30), ("3M", 90), ("1Y", 365), ("All", 0)
    ]

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    private var visiblePoints: [PricePoint] {
        let all = networkStats.hashrateHistory
        guard rangeDays > 0 else { return all }
        let cutoff = Date().addingTimeInterval(-Double(rangeDays) * 86_400)
        let windowed = all.filter { $0.timestamp >= cutoff }
        // A short window with nothing in it would draw an empty chart; fall back rather than that.
        return windowed.count >= 2 ? windowed : all
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if visiblePoints.count >= 2 {
                    PortfolioAreaChart(points: visiblePoints, onScrub: { scrubbed = $0 })
                        .frame(height: 260)
                } else {
                    ProgressView()
                        .frame(height: 260)
                        .frame(maxWidth: .infinity)
                }
                rangePicker
                MiningEstimateCard(
                    networkHashratePHs: networkStats.currentHashrate,
                    blockRewardKas: networkStats.blockRewardKas,
                    priceUsd: viewModel.currentPriceUsd,
                    currency: currency
                )
                explanation
            }
            .padding(16)
        }
        .refreshable { await networkStats.refreshIfNeeded(force: true) }
        .navigationTitle("Network Hashrate")
        .navigationBarTitleDisplayMode(.inline)
        .task { await networkStats.refreshIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Kaspa Network").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().year())
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Text((scrubbed?.value ?? networkStats.currentHashrate).map(HashrateFormat.display) ?? "—")
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.ranges, id: \.days) { range in
                Button {
                    Haptics.impact(.light)
                    scrubbed = nil
                    rangeDays = range.days
                } label: {
                    Text(range.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(rangeDays == range.days
                                           ? Color.accentColor.opacity(0.18)
                                           : Color.primary.opacity(0.06))
                        )
                        .foregroundColor(rangeDays == range.days ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About Hashrate").font(.headline)
            Text("""
            Hashrate is how much computing power miners are pointing at Kaspa. A higher hashrate \
            means more work securing the chain, and it moves with mining profitability rather than \
            with the price directly. Figures come from the Kaspa REST API set in Connection \
            Settings, at one sample per day.
            """)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }
}


/// "If I point this much hashrate at Kaspa, what do I earn?"
///
/// Straight proportional share: your hashrate over the network's, times what the network pays
/// out. Deliberately no pool fee, power cost or luck variance - those are the miner's own numbers
/// and guessing at them would make this look more precise than it is.
private struct MiningEstimateCard: View {
    /// The network's hashrate in PH/s.
    let networkHashratePHs: Double?
    let blockRewardKas: Double?
    let priceUsd: Double?
    let currency: AppCurrency

    /// Miners talk in TH/s (one KS5 Pro is about 21), so that is the default. The unit is part of
    /// the input because typing 21 and meaning PH/s is a thousandfold error, which is exactly the
    /// mistake this screen itself was shipping.
    private enum Unit: String, CaseIterable, Identifiable {
        case gh = "GH/s"
        case th = "TH/s"
        case ph = "PH/s"

        var id: String { rawValue }

        /// Multiplier to PH/s, the unit everything here is computed in.
        var toPHs: Double {
            switch self {
            case .gh: return 1e-6
            case .th: return 1e-3
            case .ph: return 1
            }
        }
    }

    @State private var amountText = "21"
    @State private var unit: Unit = .th

    /// KAS the whole network pays out per day: reward per block times blocks per second.
    private var dailyNetworkEmission: Double? {
        guard let blockRewardKas, blockRewardKas > 0 else { return nil }
        return blockRewardKas * KaspaNetworkStatsService.blocksPerSecond * 86_400
    }

    private var dailyKas: Double? {
        guard let networkHashratePHs, networkHashratePHs > 0,
              let dailyNetworkEmission,
              let amount = Double(amountText.replacingOccurrences(of: ",", with: ".")),
              amount > 0 else { return nil }
        let share = (amount * unit.toPHs) / networkHashratePHs
        return dailyNetworkEmission * share
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mining Estimate")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Picker("", selection: $unit) {
                    ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if let dailyKas {
                VStack(spacing: 8) {
                    payoutRow("Per day", kas: dailyKas)
                    Divider()
                    payoutRow("Per week", kas: dailyKas * 7)
                    Divider()
                    // 30 days, not a calendar month: the reward steps down monthly anyway, so
                    // precision past "about a month" would be false.
                    payoutRow("Per month", kas: dailyKas * 30)
                }
                .padding(.top, 2)

                Text(assumptionsLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter your hashrate to estimate earnings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private func payoutRow(_ title: String, kas: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PortfolioFormat.kas(kas))
                    .font(.subheadline.weight(.semibold))
                if let priceUsd, priceUsd > 0 {
                    Text(PortfolioFormat.currency(kas * priceUsd, currency))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Says what the number rests on, so nobody mistakes it for a promise.
    private var assumptionsLine: String {
        guard let networkHashratePHs, let blockRewardKas else { return "" }
        return "At \(HashrateFormat.display(networkHashratePHs)) network hashrate and a "
            + "\(String(format: "%.4f", blockRewardKas)) KAS block reward. Before pool fees, "
            + "power and luck, and both figures move."
    }
}
