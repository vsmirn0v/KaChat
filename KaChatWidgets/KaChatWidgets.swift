import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Shared store (mirror of PortfolioViewModel's widget types - keys MUST stay in sync)

struct PortfolioWidgetSnapshot: Codable {
    let portfolioName: String
    let currentValue: Double
    let changeAmount: Double?
    let changePercent: Double?
    let kasPrice: Double
    let priceChange24hPercent: Double?
    let kasUnits: Double
    let currencySymbol: String
    let currencyCode: String
    let updatedAt: Date
    /// Optional so stores written by older app builds still decode.
    let sparkline24h: [Double]?
}

struct PortfolioWidgetStore: Codable {
    struct Entry: Codable {
        let id: String
        let name: String
    }
    let snapshots: [String: PortfolioWidgetSnapshot]
    let portfolios: [Entry]
    let activeId: String?

    static let appGroupId = "group.com.kachat.app"
    static let storageKey = "kachat_portfolio_widget_store"

    static func load() -> PortfolioWidgetStore? {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PortfolioWidgetStore.self, from: data)
    }

    /// The snapshot for a selected portfolio id, defaulting to the app's active portfolio,
    /// then to any portfolio at all.
    func snapshot(forSelectedId selectedId: String?) -> PortfolioWidgetSnapshot? {
        if let selectedId, let chosen = snapshots[selectedId] { return chosen }
        if let activeId, let active = snapshots[activeId] { return active }
        return portfolios.first.flatMap { snapshots[$0.id] }
    }
}

// MARK: - Configuration intent (long-press -> Edit Widget -> pick the portfolio)

struct WidgetPortfolioEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Portfolio"
    static let defaultQuery = WidgetPortfolioQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WidgetPortfolioQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetPortfolioEntity] {
        let store = PortfolioWidgetStore.load()
        return identifiers.compactMap { id in
            store?.portfolios.first { $0.id == id }.map { WidgetPortfolioEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [WidgetPortfolioEntity] {
        (PortfolioWidgetStore.load()?.portfolios ?? []).map { WidgetPortfolioEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> WidgetPortfolioEntity? {
        guard let store = PortfolioWidgetStore.load() else { return nil }
        if let activeId = store.activeId, let active = store.portfolios.first(where: { $0.id == activeId }) {
            return WidgetPortfolioEntity(id: active.id, name: active.name)
        }
        return store.portfolios.first.map { WidgetPortfolioEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectPortfolioIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Portfolio"
    static let description = IntentDescription("Pick which portfolio this widget tracks.")

    @Parameter(title: "Portfolio")
    var portfolio: WidgetPortfolioEntity?
}

// MARK: - Timeline

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let snapshot: PortfolioWidgetSnapshot?
}

struct PortfolioTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: Date(), snapshot: .placeholder)
    }

    func snapshot(for configuration: SelectPortfolioIntent, in context: Context) async -> PortfolioEntry {
        PortfolioEntry(
            date: Date(),
            snapshot: PortfolioWidgetStore.load()?.snapshot(forSelectedId: configuration.portfolio?.id) ?? .placeholder
        )
    }

    func timeline(for configuration: SelectPortfolioIntent, in context: Context) async -> Timeline<PortfolioEntry> {
        var snapshot = PortfolioWidgetStore.load()?.snapshot(forSelectedId: configuration.portfolio?.id)
        // Freshen the value with a live KAS price between app opens: units are stable, so
        // value = units * fresh price. Change figures stay from the app's last computation.
        if let stored = snapshot, stored.kasUnits > 0,
           let fresh = await Self.fetchLivePrice(currencyCode: stored.currencyCode) {
            snapshot = PortfolioWidgetSnapshot(
                portfolioName: stored.portfolioName,
                currentValue: stored.kasUnits * fresh.price,
                changeAmount: stored.changeAmount,
                changePercent: stored.changePercent,
                kasPrice: fresh.price,
                priceChange24hPercent: fresh.change24h ?? stored.priceChange24hPercent,
                kasUnits: stored.kasUnits,
                currencySymbol: stored.currencySymbol,
                currencyCode: stored.currencyCode,
                updatedAt: Date(),
                sparkline24h: stored.sparkline24h
            )
        }
        let entry = PortfolioEntry(date: Date(), snapshot: snapshot)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// Same CoinGecko endpoint the app uses, kept tiny and self-contained for the extension.
    private static func fetchLivePrice(currencyCode: String) async -> (price: Double, change24h: Double?)? {
        let code = currencyCode.lowercased()
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: "kaspa"),
            URLQueryItem(name: "vs_currencies", value: code),
            URLQueryItem(name: "include_24hr_change", value: "true")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) != false,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kaspa = json["kaspa"] as? [String: Any],
              let price = kaspa[code] as? Double else { return nil }
        return (price, kaspa["\(code)_24h_change"] as? Double)
    }
}

extension PortfolioWidgetSnapshot {
    static let placeholder = PortfolioWidgetSnapshot(
        portfolioName: "Portfolio",
        currentValue: 1234.56,
        changeAmount: 42.10,
        changePercent: 3.5,
        kasPrice: 0.1234,
        priceChange24hPercent: 2.1,
        kasUnits: 10_000,
        currencySymbol: "$",
        currencyCode: "USD",
        updatedAt: Date(),
        sparkline24h: [0.11, 0.115, 0.112, 0.118, 0.121, 0.119, 0.123, 0.1234]
    )
}

// MARK: - Views

struct PortfolioWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PortfolioEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium:
                    mediumView(snapshot)
                default:
                    smallView(snapshot)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "chart.pie")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Open KaChat to set up your portfolio")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .widgetURL(URL(string: "kachat://portfolio"))
    }

    private func smallView(_ snapshot: PortfolioWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chart.pie.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text(snapshot.portfolioName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(formatValue(snapshot.currentValue, symbol: snapshot.currencySymbol))
                .font(.title3.weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            changeBadge(amount: snapshot.changeAmount, percent: snapshot.changePercent, symbol: snapshot.currencySymbol)
            Spacer(minLength: 2)
            Text("KAS \(formatPrice(snapshot.kasPrice, symbol: snapshot.currencySymbol))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mediumView(_ snapshot: PortfolioWidgetSnapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.pie.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(snapshot.portfolioName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(formatValue(snapshot.currentValue, symbol: snapshot.currencySymbol))
                    .font(.title3.weight(.bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                changeBadge(amount: snapshot.changeAmount, percent: snapshot.changePercent, symbol: snapshot.currencySymbol)
            }
            if let points = snapshot.sparkline24h, points.count >= 2 {
                SparklineView(
                    points: points,
                    tint: (snapshot.priceChange24hPercent ?? 0) >= 0 ? .green : .red
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            } else {
                Spacer()
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("KAS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(formatPrice(snapshot.kasPrice, symbol: snapshot.currencySymbol))
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if let change = snapshot.priceChange24hPercent {
                    Text(String(format: "%+.1f%% 24h", change))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(change >= 0 ? .green : .red)
                }
                Text(snapshot.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changeBadge(amount: Double?, percent: Double?, symbol: String) -> some View {
        Group {
            if let amount, let percent {
                Text("\(amount >= 0 ? "+" : "-")\(symbol)\(String(format: "%.2f", abs(amount))) (\(String(format: "%+.1f%%", percent)))")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(amount >= 0 ? .green : .red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("--")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatValue(_ value: Double, symbol: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = value >= 1000 ? 0 : 2
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        return symbol + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    private func formatPrice(_ value: Double, symbol: String) -> String {
        symbol + String(format: value < 1 ? "%.5f" : "%.2f", value)
    }
}

struct PortfolioWidget: Widget {
    // V2 suffix: the original kind got stuck in iOS's widget cache as the pre-configurable
    // definition (no Edit options, broken medium) - a fresh kind forces a fresh registration.
    let kind = "KaChatPortfolioWidgetV2"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPortfolioIntent.self, provider: PortfolioTimelineProvider()) { entry in
            PortfolioWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Portfolio")
        .description("Track a portfolio's value and the live KAS price. Long-press to choose which portfolio.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}


/// Minimal 24h price sparkline - a normalized Path, no Charts dependency.
struct SparklineView: View {
    let points: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let minValue = points.min() ?? 0
            let maxValue = points.max() ?? 1
            let range = max(maxValue - minValue, maxValue * 0.001, 0.000001)
            let stepX = geo.size.width / CGFloat(points.count - 1)
            let path = Path { p in
                for (index, value) in points.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = geo.size.height * (1 - CGFloat((value - minValue) / range))
                    if index == 0 {
                        p.move(to: CGPoint(x: x, y: y))
                    } else {
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            path.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
