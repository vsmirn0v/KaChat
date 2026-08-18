import SwiftUI

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
    private let ranges: [(label: String, days: Int)] = [("1D", 1), ("1W", 7), ("1M", 30), ("3M", 90), ("1Y", 365)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                chart
                rangePicker
            }
            .padding(16)
        }
        .navigationTitle("KAS Price")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline).foregroundColor(.secondary)
                Text(PortfolioFormat.price(scrub.value, currency: currency))
                    .font(.system(size: 34, weight: .bold))
            } else {
                HStack(spacing: 8) {
                    Image("KaspaLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                    Text("Kaspa").font(.title3).fontWeight(.semibold)
                }
                Text(viewModel.currentPriceUsd.map { PortfolioFormat.price($0, currency: currency) } ?? "—")
                    .font(.system(size: 34, weight: .bold))
                if let change = viewModel.priceChange24h {
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
            SparklineChart(points: viewModel.priceHistory, lineWidth: 2.5, dotRadius: 5, onScrub: { scrubbed = $0 })
                .frame(height: 240)
        } else {
            ProgressView()
                .frame(height: 240)
                .frame(maxWidth: .infinity)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(ranges, id: \.days) { range in
                Button {
                    Haptics.impact(.light)
                    scrubbed = nil
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

// MARK: - Portfolio value full-screen chart + stats

private struct PortfolioValueChartScreen: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var scrubbed: PricePoint?

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    var body: some View {
        let summary = viewModel.summary
        let history = viewModel.valueHistory
        let displayed = scrubbed ?? history.last

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scrubbed != nil
                         ? "Value on \(scrubbed!.timestamp.formatted(date: .abbreviated, time: .omitted))"
                         : "Portfolio Value")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text(PortfolioFormat.currency(displayed?.value ?? summary.currentValue, currency))
                        .font(.system(size: 34, weight: .bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if history.count >= 2 {
                    SparklineChart(points: history, lineWidth: 3, dotRadius: 6, onScrub: { scrubbed = $0 })
                        .frame(height: 220)
                } else {
                    Text("Not enough history yet - check back after a few days of activity.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                }

                statsCard(summary)
            }
            .padding(16)
        }
        .navigationTitle("Value Over Time")
        .navigationBarTitleDisplayMode(.inline)
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

/// Hand-rolled line chart with optional drag-to-scrub. Normalizes points to the view's frame,
/// no drawn axes/labels (matches the compact sparkline style used throughout Portfolio).
private struct SparklineChart: View {
    let points: [PricePoint]
    var lineWidth: CGFloat = 2.5
    var dotRadius: CGFloat = 4
    var onScrub: ((PricePoint?) -> Void)?

    @State private var scrubIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            chartContent(size: proxy.size)
        }
    }

    @ViewBuilder
    private func chartContent(size: CGSize) -> some View {
        let values = points.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = (maxValue - minValue) > 0 ? (maxValue - minValue) : 1
        let stepX = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0

        let content = ZStack {
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = size.height - CGFloat((point.value - minValue) / range) * size.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            if let index = scrubIndex, index < points.count {
                let x = CGFloat(index) * stepX
                let y = size.height - CGFloat((points[index].value - minValue) / range) * size.height
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: dotRadius * 2, height: dotRadius * 2)
                    .position(x: x, y: y)
            }
        }
        .contentShape(Rectangle())

        if let onScrub {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard stepX > 0 else { return }
                        let index = min(max(Int((value.location.x / stepX).rounded()), 0), points.count - 1)
                        scrubIndex = index
                        onScrub(points[index])
                    }
                    .onEnded { _ in
                        scrubIndex = nil
                        onScrub(nil)
                    }
            )
        } else {
            content
        }
    }
}
