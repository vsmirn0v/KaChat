import SwiftUI
import Charts

struct PortfolioView: View {
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @ObservedObject private var portfolioManager = PortfolioManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showPriceChart = false
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
                        onDelete: { portfolioManager.deletePortfolio($0) }
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
                aboutKaspa
            }
            .padding(16)
        }
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

    private var aboutKaspa: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About Kaspa").font(.headline)
            Text(Self.kaspaDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    // Original factual summary (paraphrased, not copied from any single source).
    private static let kaspaDescription = """
    Kaspa is a decentralized, open-source, proof-of-work cryptocurrency. It is built on the \
    GHOSTDAG protocol - a generalization of Nakamoto consensus that, instead of discarding blocks \
    created in parallel, orders them together in a blockDAG. This lets Kaspa reach very high block \
    rates and near-instant transaction confirmation while keeping the security guarantees of \
    proof of work. Kaspa launched in November 2021 with a fair release: no pre-mine, no pre-sale, \
    and no coin allocations. Its native coin is KAS.
    """
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
                AxisValueLabel()
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
