import SwiftUI

/// One kind of KaChat transaction the stats screen counts. The raw value is the key in the
/// indexer's `GET /stats` response (STATS_INDEXER.md), so it is part of that contract - don't
/// rename a case without the server.
enum KaChatStatCategory: String, CaseIterable, Identifiable {
    case messages, handshakes, payments
    case groupMessages, groupUpdates, publicChats
    case kaposts, kapostActions
    case chessMoves, chessGames
    case selfStash

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .messages: return "Direct Messages"
        case .handshakes: return "New Chats"
        case .payments: return "Payments"
        case .groupMessages: return "Group Messages"
        case .groupUpdates: return "Group Updates"
        case .publicChats: return "Public Chats"
        case .kaposts: return "KaPosts"
        case .kapostActions: return "KaPost Activity"
        case .chessMoves: return "Chess Moves"
        case .chessGames: return "Chess Games"
        case .selfStash: return "Saved Records"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .messages: return "1:1 texts, voice notes, reactions and 1:1 chess"
        case .handshakes: return "Handshakes that start a 1:1 chat"
        case .payments: return "KAS sent in chats"
        case .groupMessages: return "Messages in group chats"
        case .groupUpdates: return "Creating groups, invites and other changes"
        case .publicChats: return "Messages in public rooms"
        case .kaposts: return "Posts, replies, quotes and polls"
        case .kapostActions: return "Votes, follows, edits and deletes"
        case .chessMoves: return "Moves played in Chess Online"
        case .chessGames: return "Games started in Chess Online"
        case .selfStash: return "Chat keys and contact notes saved to your own account"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .handshakes: return "hand.wave.fill"
        case .payments: return "paperplane.fill"
        case .groupMessages: return "person.3.fill"
        case .groupUpdates: return "person.badge.plus"
        case .publicChats: return "dot.radiowaves.left.and.right"
        case .kaposts: return "text.bubble.fill"
        case .kapostActions: return "hand.thumbsup.fill"
        case .chessMoves: return "checkerboard.rectangle"
        case .chessGames: return "trophy.fill"
        case .selfStash: return "tray.full.fill"
        }
    }

    var color: Color {
        switch self {
        case .messages: return .blue
        case .handshakes: return .cyan
        case .payments: return .green
        case .groupMessages: return .indigo
        case .groupUpdates: return .teal
        case .publicChats: return .orange
        case .kaposts: return .pink
        case .kapostActions: return .purple
        case .chessMoves: return .brown
        case .chessGames: return .yellow
        case .selfStash: return .gray
        }
    }
}

enum KaChatStatRange: String, CaseIterable, Hashable {
    case day, week, all

    var title: String {
        switch self {
        case .day: return "24 Hours"
        case .week: return "7 Days"
        case .all: return "All Time"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .day: return "KaChat transactions in the last 24 hours"
        case .week: return "KaChat transactions in the last 7 days"
        case .all: return "KaChat transactions on Kaspa, all time"
        }
    }
}

/// One category's counts as an indexer reports them. Every field is optional: a server that
/// only keeps an all-time counter still works, the shorter ranges just show a dash.
struct KaChatStatCounts: Decodable, Equatable {
    let total: Int64?
    let last24h: Int64?
    let last7d: Int64?

    func value(for range: KaChatStatRange) -> Int64? {
        switch range {
        case .day: return last24h
        case .week: return last7d
        case .all: return total
        }
    }
}

struct KaChatStatsSnapshot: Equatable {
    var counts: [KaChatStatCategory: KaChatStatCounts]
    var updatedAt: Date?
    var indexedSince: Date?
    var fetchedAt: Date
}

/// Fetches and holds the stats. Shared so switching tabs and coming back doesn't refetch: a
/// snapshot younger than a minute is reused unless the user pulls to refresh.
@MainActor
final class KaChatStatsModel: ObservableObject {
    static let shared = KaChatStatsModel()

    enum Failure: Equatable {
        /// No KaChat indexer is set for this network (testnet, for now).
        case noIndexer
        /// No indexer answered `/stats` with anything this app knows.
        case unavailable
    }

    @Published private(set) var snapshot: KaChatStatsSnapshot?
    @Published private(set) var failure: Failure?
    @Published private(set) var isLoading = false

    private var sourceKey = ""
    private static let freshFor: TimeInterval = 60

    func refresh(force: Bool) async {
        let bases = Self.indexerBases()
        let key = bases.joined(separator: "|")
        if key != sourceKey {
            // Another network or indexer: the old numbers aren't this server's.
            sourceKey = key
            snapshot = nil
            failure = nil
        }
        guard !bases.isEmpty else {
            failure = .noIndexer
            return
        }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.freshFor { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let fetched = await Self.fetch(from: bases)
        guard key == sourceKey else { return }
        if let fetched {
            snapshot = fetched
            failure = nil
        } else {
            // Keep showing the last numbers, if there are any; the screen says they're stale.
            failure = .unavailable
        }
    }

    /// Every KaChat indexer this network is configured with, deduplicated - by default they are
    /// all the same server, so this is one request.
    private static func indexerBases() -> [String] {
        let settings = AppSettings.load()
        var seen = Set<String>()
        return [settings.indexerURL, settings.publicChatIndexerURL, settings.kaPostIndexerURL]
            .map { url -> String in
                var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private struct Response: Decodable {
        let updatedAt: Int64?
        let indexedSince: Int64?
        let categories: [String: KaChatStatCounts]
    }

    /// Asks each indexer for `/stats` and merges: a category comes from the first indexer (in
    /// settings order) that reports it, so one server can report everything or each its own
    /// slice. Nil when none of them reports a single category this app knows.
    private nonisolated static func fetch(from bases: [String]) async -> KaChatStatsSnapshot? {
        let responses = await withTaskGroup(of: (Int, Response?).self) { group -> [Response] in
            for (index, base) in bases.enumerated() {
                group.addTask { (index, await fetchOne(base)) }
            }
            var collected: [(Int, Response)] = []
            for await (index, response) in group {
                if let response { collected.append((index, response)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var counts: [KaChatStatCategory: KaChatStatCounts] = [:]
        for response in responses {
            for (key, value) in response.categories {
                guard let category = KaChatStatCategory(rawValue: key), counts[category] == nil else { continue }
                counts[category] = value
            }
        }
        guard !counts.isEmpty else { return nil }

        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        return KaChatStatsSnapshot(
            counts: counts,
            updatedAt: responses.compactMap { date($0.updatedAt) }.max(),
            indexedSince: responses.compactMap { date($0.indexedSince) }.min(),
            fetchedAt: Date()
        )
    }

    private nonisolated static func fetchOne(_ base: String) async -> Response? {
        guard let url = URL(string: "\(base)/stats") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return nil
        }
    }
}

/// Kaspa Hub > KaChat Stats: how many transactions KaChat has put on Kaspa, split by kind -
/// direct messages, payments, group and public chat messages, KaPosts, chess moves and so on.
///
/// The numbers are the indexers' (`GET /stats`, STATS_INDEXER.md), never this phone's own
/// traffic. A category no indexer reports is left out rather than shown as zero; while loading,
/// or when the indexer has no stats yet, the rows keep their real names with the numbers
/// redacted, so nothing invented is ever on screen.
struct KaChatStatsView: View {
    @ObservedObject private var model = KaChatStatsModel.shared
    @State private var range: KaChatStatRange = .all
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    UnderlineTabBar(
                        tabs: KaChatStatRange.allCases.map { (tab: $0, title: $0.title) },
                        selection: $range
                    )
                    if let snapshot = model.snapshot {
                        shareBar(snapshot)
                        categoryList(snapshot)
                    } else {
                        if let failure = model.failure, !model.isLoading {
                            unavailableCard(failure)
                        }
                        placeholderList
                    }
                    footer
                }
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refresh(force: true) }
            .task { await model.refresh(force: false) }
            .navigationTitle("KaChat Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel(Text("What counts"))
                }
            }
            .sheet(isPresented: $showInfo) { infoSheet }
        }
    }

    // MARK: - Numbers

    private struct Row: Identifiable {
        let category: KaChatStatCategory
        /// Nil when the indexer reports the category but not this range.
        let value: Int64?
        var id: KaChatStatCategory { category }
    }

    /// The categories the indexer reports, in the fixed display order.
    private func reported(_ snapshot: KaChatStatsSnapshot) -> [Row] {
        KaChatStatCategory.allCases.compactMap { category in
            guard let counts = snapshot.counts[category] else { return nil }
            return Row(category: category, value: counts.value(for: range))
        }
    }

    private func total(_ snapshot: KaChatStatsSnapshot) -> Int64? {
        let values = reported(snapshot).compactMap { $0.value }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.bottom, 4)
            Group {
                if let snapshot = model.snapshot, let total = total(snapshot) {
                    Text(total.formatted())
                } else if model.snapshot != nil {
                    Text(verbatim: "—")
                } else {
                    Text(verbatim: "000,000").redacted(reason: .placeholder)
                }
            }
            .font(.system(size: 44, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(range.caption)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: - Share bar and rows

    /// Each category's share of the range's total as one segmented bar.
    private func shareBar(_ snapshot: KaChatStatsSnapshot) -> some View {
        let parts = reported(snapshot).filter { ($0.value ?? 0) > 0 }
        let sum = parts.reduce(Int64(0)) { $0 + ($1.value ?? 0) }
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                if sum > 0 {
                    ForEach(parts) { part in
                        part.category.color
                            .frame(width: max(3, (proxy.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(Double(part.value ?? 0) / Double(sum))))
                    }
                } else {
                    Color(.tertiarySystemFill)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }

    private func categoryList(_ snapshot: KaChatStatsSnapshot) -> some View {
        let rows = reported(snapshot)
        let sum = total(snapshot) ?? 0
        return card {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                categoryRow(row.category) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let value = row.value {
                            Text(value.formatted())
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if sum > 0 {
                                Text((Double(value) / Double(sum)).formatted(.percent.precision(.fractionLength(0...1))))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        } else {
                            Text(verbatim: "—")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if index < rows.count - 1 { Divider().padding(.leading, 60) }
            }
        }
    }

    /// Real category names with the numbers redacted - while loading, or when the indexer has no
    /// stats yet.
    private var placeholderList: some View {
        let categories = KaChatStatCategory.allCases
        return card {
            ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                categoryRow(category) {
                    Text(verbatim: "00,000")
                        .font(.subheadline.weight(.semibold))
                        .redacted(reason: .placeholder)
                }
                if index < categories.count - 1 { Divider().padding(.leading, 60) }
            }
        }
    }

    private func categoryRow<Value: View>(_ category: KaChatStatCategory, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(category.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.subheadline.weight(.semibold))
                Text(category.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
    }

    // MARK: - States and footer

    private func unavailableCard(_ failure: KaChatStatsModel.Failure) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.secondary)
            switch failure {
            case .noIndexer:
                Text("No indexer is set for this network")
                    .font(.headline)
                Text("Add one in Settings > Connection Settings to see KaChat stats.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            case .unavailable:
                Text("Stats aren't available yet")
                    .font(.headline)
                Text("Your indexer doesn't report KaChat stats yet. They'll show here once it does.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.refresh(force: true) }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var footer: some View {
        if let snapshot = model.snapshot {
            VStack(spacing: 4) {
                if model.failure == .unavailable {
                    Text("Couldn't refresh. Showing the last numbers.")
                }
                Text("Updated \(Self.relative(snapshot.updatedAt ?? snapshot.fetchedAt))")
                if let since = snapshot.indexedSince {
                    Text("Counting since \(since.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, Date()), relativeTo: Date())
    }

    // MARK: - What counts

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(KaChatStatCategory.allCases) { category in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: category.icon)
                                .font(.title3)
                                .foregroundColor(category.color)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.title).font(.subheadline.weight(.semibold))
                                Text(category.detail).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Every KaChat action is its own Kaspa transaction. These totals come from KaChat's indexer, counting what it has seen on chain - nothing is read from your phone.")
                        .textCase(nil)
                } footer: {
                    Text("1:1 messages are encrypted, so voice notes, reactions and 1:1 chess moves count as direct messages: nobody, the indexer included, can tell them apart.")
                }
            }
            .navigationTitle("What counts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
