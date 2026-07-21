import SwiftUI

struct PortfolioView: View {
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var valueScrubX: CGFloat?
    @State private var valueCanvasWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    priceChartCard
                    if viewModel.valueHistory.count >= 2 {
                        valueChartCard
                    }
                    transactionsNavRow
                }
                .padding()
            }
            .refreshable {
                await viewModel.refreshPriceAsync()
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
        }
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
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let scrub = viewModel.scrubbedPricePoint {
                    Text(scrub.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(Self.formatPrice(scrub.value))
                        .font(.system(size: 26, weight: .bold))
                } else {
                    Text("KAS Price")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(viewModel.currentPriceUsd.map(Self.formatPrice) ?? "—")
                        .font(.system(size: 26, weight: .bold))
                }
            }

            HStack(alignment: .top) {
                statColumn(label: "Holdings", value: Self.formatKas(summary.holdingsKas), alignment: .leading)
                Spacer()
                statColumn(label: "Current Value", value: Self.formatCurrency(summary.currentValue), alignment: .trailing)
            }

            Divider()

            HStack(alignment: .top) {
                statColumn(label: "Total Invested", value: Self.formatCurrency(summary.totalInvested), alignment: .leading)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total P&L")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: summary.totalPL >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline)
                        Text("\(Self.formatCurrency(summary.totalPL)) (\(String(format: "%.1f", summary.totalPLPercent))%)")
                            .font(.title3)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(summary.totalPL >= 0 ? .green : .red)
                }
            }

            if let averageBuyPriceUsd = summary.averageBuyPriceUsd {
                Divider()
                HStack(alignment: .top) {
                    statColumn(label: "Avg. Buy Price", value: Self.formatPrice(averageBuyPriceUsd), alignment: .leading)
                    Spacer()
                }
            }
        }
        .padding(16)
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

    private static func formatPrice(_ value: Double) -> String {
        let decimals = value < 1 ? 5 : 2
        return "$" + String(format: "%.\(decimals)f", value)
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

    private static func formatCurrency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
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
        .padding(.vertical, 14)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Value-over-time chart

    private var valueChartCard: some View {
        let history = viewModel.valueHistory
        let selectedIndex: Int? = {
            guard let x = valueScrubX, valueCanvasWidth > 0 else { return nil }
            let ratio = x / valueCanvasWidth
            let index = Int((ratio * CGFloat(history.count - 1)).rounded())
            return min(max(index, 0), history.count - 1)
        }()
        let displayed = selectedIndex.map { history[$0] } ?? history.last

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let index = selectedIndex {
                    Text("Value on \(history[index].timestamp.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Value Over Time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let displayed {
                    Text(displayed.value, format: .currency(code: "USD"))
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }

            SparklineChart(
                points: history,
                lineWidth: 3.5,
                dotRadius: 6,
                onScrub: nil
            )
            .frame(height: 90)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { valueCanvasWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { valueCanvasWidth = $0 }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { valueScrubX = $0.location.x }
                    .onEnded { _ in valueScrubX = nil }
            )
        }
        .padding(16)
        .background(glassBackground(cornerRadius: 18))
    }

    // MARK: - Transactions nav row

    private var transactionsNavRow: some View {
        NavigationLink {
            PortfolioTransactionsView(viewModel: viewModel)
        } label: {
            HStack {
                Image(systemName: "receipt")
                    .foregroundColor(.accentColor)
                Text("Transactions")
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(glassBackground(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
