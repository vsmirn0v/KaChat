import SwiftUI

private enum PortfolioContentTab: Hashable {
    case data
    case transactions
}

struct PortfolioView: View {
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @ObservedObject private var portfolioManager = PortfolioManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var scrubbedValuePoint: PricePoint?
    @State private var selectedContentTab: PortfolioContentTab = .data

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PortfolioPickerHeader(
                    portfolios: portfolioManager.portfolios,
                    activePortfolioId: portfolioManager.activePortfolioId,
                    cardModel: cardModel(for:),
                    formatCurrency: formatCurrency,
                    onSelect: { portfolioManager.setActivePortfolio($0) },
                    onAdd: { portfolioManager.addPortfolio(name: $0) },
                    onRename: { portfolioManager.renamePortfolio($0, to: $1) },
                    onDelete: { portfolioManager.deletePortfolio($0) }
                )
                contentTabBar

                // .page style gives left/right swipe between tabs for free, kept in sync with
                // contentTabBar's buttons via the shared $selectedContentTab binding; index dots
                // are hidden since that tab bar is already the visible selector.
                TabView(selection: $selectedContentTab) {
                    dataTabContent
                        .tag(PortfolioContentTab.data)
                    PortfolioTransactionsView(viewModel: viewModel)
                        .tag(PortfolioContentTab.transactions)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var dataTabContent: some View {
        ScrollView {
            // Matches Android's Data tab spacing (12.dp outer padding, 10.dp between cards) -
            // this was previously 16pt everywhere, tall enough to force a scroll on most iPhones
            // even though every card's content already fits without it.
            VStack(spacing: 10) {
                summaryCard
                priceChartCard
                if viewModel.valueHistory.count >= 2 {
                    valueChartCard
                }
            }
            .padding(12)
        }
        .refreshable {
            await viewModel.refreshPriceAsync()
        }
    }

    // MARK: - Data / Transactions tab bar (styled like ChatListView's Chats/Group Chats tabs)

    private var contentTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                contentTabButton("Data", tab: .data)
                contentTabButton("Transactions", tab: .transactions)
            }
            Divider()
        }
        .background(.ultraThinMaterial)
    }

    private func contentTabButton(_ title: String, tab: PortfolioContentTab) -> some View {
        let isSelected = selectedContentTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedContentTab = tab }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)

                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
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

    private func rangeLabel(_ days: Int) -> String {
        switch days {
        case 1: return "1d"
        case 7: return "7d"
        default: return "30d"
        }
    }

    // MARK: - Summary card (price header + holdings/value + invested/P&L)

    private var summaryCard: some View {
        let summary = viewModel.summary
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let scrub = viewModel.scrubbedPricePoint {
                    Text(scrub.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(formatPrice(scrub.value))
                        .font(.system(size: 26, weight: .bold))
                } else {
                    Text("KAS Price")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(viewModel.currentPriceUsd.map(formatPrice) ?? "—")
                            .font(.system(size: 26, weight: .bold))
                        if let change = viewModel.priceChange24h {
                            HStack(spacing: 2) {
                                Image(systemName: change >= 0 ? "arrow.up" : "arrow.down")
                                    .font(.caption2)
                                Text("\(String(format: "%.2f", abs(change)))%")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(change >= 0 ? .green : .red)
                        }
                    }
                }
            }

            HStack(alignment: .top) {
                statColumn(label: "Holdings", value: Self.formatKas(summary.holdingsKas), alignment: .leading)
                Spacer()
                statColumn(label: "Current Value", value: formatCurrency(summary.currentValue), alignment: .trailing)
            }

            Divider()

            HStack(alignment: .top) {
                statColumn(label: "Total Invested", value: formatCurrency(summary.totalInvested), alignment: .leading)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total P&L")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: summary.totalPL >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline)
                        Text("\(formatCurrency(summary.totalPL)) (\(String(format: "%.1f", summary.totalPLPercent))%)")
                            .font(.title3)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(summary.totalPL >= 0 ? .green : .red)
                }
            }

            if let averageBuyPriceUsd = summary.averageBuyPriceUsd {
                Divider()
                HStack(alignment: .top) {
                    statColumn(label: "Avg. Buy Price", value: formatPrice(averageBuyPriceUsd), alignment: .leading)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(glassBackground(cornerRadius: 18))
    }

    private func statColumn(label: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
        }
    }

    private static func currencySymbol(for currency: AppCurrency) -> String {
        // Not ISO 4217 - NumberFormatter's fallback behavior for an unrecognized currency code
        // isn't reliably "show the code", so this is spelled out explicitly rather than trusted
        // to the formatter below.
        if currency == .bitcoin { return "₿" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        return formatter.currencySymbol ?? currency.code
    }

    private func formatPrice(_ value: Double) -> String {
        let decimals = value < 1 ? 5 : 2
        return Self.currencySymbol(for: settingsViewModel.settings.currency) + String(format: "%.\(decimals)f", value)
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

    private static func formatKas(_ value: Double) -> String {
        let text = kasFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        return text + " KAS"
    }

    /// Builds the string manually via `currencySymbol(for:)` rather than `.formatted(.currency(code:))` -
    /// the latter is Foundation's ISO-4217-driven `FormatStyle`, whose behavior for a
    /// non-ISO-4217 code like `.bitcoin`'s "BTC" isn't something to rely on sight-unseen.
    private func formatCurrency(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return sign + Self.currencySymbol(for: settingsViewModel.settings.currency) + magnitude
    }

    // MARK: - Price chart card (label left, sparkline right)

    private var priceChartCard: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.impact(.light)
                viewModel.cyclePriceRange()
            } label: {
                Text("Price (\(rangeLabel(viewModel.priceRangeDays)))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if viewModel.priceHistory.count >= 2 {
                SparklineChart(
                    points: viewModel.priceHistory,
                    lineWidth: 2,
                    onScrub: { viewModel.scrubbedPricePoint = $0 }
                )
                .frame(height: 40)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Value-over-time chart

    private var valueChartCard: some View {
        let history = viewModel.valueHistory
        let displayed = scrubbedValuePoint ?? history.last

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let scrubbedValuePoint {
                    Text("Value on \(scrubbedValuePoint.timestamp.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Value Over Time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let displayed {
                    Text(formatCurrency(displayed.value))
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }

            // Passing `onScrub` (rather than `nil`, as before) is what actually turns on
            // `SparklineChart`'s own crosshair line+dot - it was previously drawing that overlay
            // from an internal `scrubIndex` that a `nil` onScrub never let anything set, while
            // this view instead ran its own separate, redundant drag gesture that only updated
            // the text label above, never the chart itself. Matches how `priceChartCard` already
            // does it.
            SparklineChart(
                points: history,
                lineWidth: 3.5,
                dotRadius: 6,
                onScrub: { scrubbedValuePoint = $0 }
            )
            .frame(height: 90)
        }
        .padding(14)
        .background(glassBackground(cornerRadius: 18))
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
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
