import Combine
import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class PortfolioViewModel: ObservableObject {
    /// Shared instance so writes from outside Portfolio itself (e.g. SwapService's "Add to
    /// Portfolio" after a finished swap) update the same `@Published transactions` array
    /// PortfolioView is observing, instead of writing straight to PortfolioLedgerStore behind
    /// its back - that used to leave Portfolio showing stale data until the app was relaunched
    /// (the view model only ever loaded from disk once, in its own init).
    static let shared = PortfolioViewModel()

    @Published private(set) var transactions: [PortfolioTransaction] = []
    /// Current KAS price in whatever `AppSettings.currency` is selected (not necessarily USD
    /// despite the name - kept as-is to minimize churn across the many call sites already reading
    /// it; see `currentCurrency` for the currency it's actually denominated in).
    @Published private(set) var currentPriceUsd: Double?
    /// KAS price's percent change over the last 24 hours, from CoinGecko's own rolling 24h
    /// figure (not derived from `priceHistory`, which is a chart-range the user can toggle) —
    /// shown next to the price in `summaryCard`. Nil while unavailable rather than 0, so the UI
    /// can distinguish "no data yet" from "flat".
    @Published private(set) var priceChange24h: Double?
    @Published private(set) var priceHistory: [PricePoint] = []
    @Published private(set) var priceRangeDays: Int = 1
    @Published var scrubbedPricePoint: PricePoint?
    /// A 7-day price history kept independent of `priceHistory`'s user-selected chart range
    /// (1/7/30d) — the portfolio picker header's "today's change" per-card figures need a
    /// stable window that doesn't shift just because the user toggled the visible chart.
    @Published private(set) var sevenDayPriceHistory: [PricePoint] = []

    /// The currency `currentPriceUsd`/`priceHistory` are actually denominated in - re-read from
    /// `AppSettings` on every `.settingsDidChange` notification, refetching both if it changed.
    private(set) var currentCurrency: AppCurrency = SettingsViewModel.loadSettings().currency
    private var settingsObserver: NSObjectProtocol?
    /// Forwards `PortfolioManager.shared.activePortfolioId` changes into this object's own
    /// `objectWillChange` — `scopedTransactions`/`summary`/`valueHistory` are plain computed
    /// properties with no `@Published` of their own, so without this, any view that observes
    /// only `PortfolioViewModel` (not also `PortfolioManager`, e.g. `PortfolioTransactionsView`
    /// embedded in the swipeable tab) never re-renders when the active portfolio switches —
    /// confirmed via on-device repro: the Transactions tab kept showing the previous portfolio's
    /// ledger after tapping a different portfolio card.
    private var portfolioSwitchCancellable: AnyCancellable?
    private var widgetSnapshotCancellable: AnyCancellable?
    private var portfolioListCancellable: AnyCancellable?

    /// Per-range (days -> history) cache. Re-selecting an already-fetched range applies
    /// instantly with no network call, and (more importantly) avoids hitting CoinGecko's
    /// public-API rate limit from repeated taps of the range cycle. Cleared only by
    /// refreshPrice() (an explicit "get me current data" action) — selecting a range merely
    /// serves from cache or fetches once per range per session.
    private var priceHistoryCache: [Int: [PricePoint]] = [:]
    /// One in-flight fetch per range (days). A range switch does NOT cancel the previous
    /// range's fetch - it completes into its own cache so tapping back is instant, and its
    /// completion only paints `priceHistory` if its range is still the selected one. Tapping
    /// a range whose fetch is already in flight is a no-op (dedup), so rapid cycling through
    /// all five ranges costs at most one request per range instead of a 429-triggering burst.
    private var priceHistoryTasks: [Int: Task<Void, Never>] = [:]
    /// Bumped by `cancelPriceHistoryTasks()` (explicit refresh). Each fetch task captures the
    /// epoch at start and refuses to write results or clean up `priceHistoryTasks` once it's
    /// stale - same epoch pattern the chat send-menu gesture uses for ownership.
    private var priceHistoryEpoch = 0
    private let coinGecko: CoinGeckoService
    private var activeWalletAddress: String?
    /// The one background price-backfill loop (see `startPriceBackfillIfNeeded`) — nil when
    /// idle. Cancelled on wallet switch/clear so a pass never writes into the wrong ledger.
    private var priceBackfillTask: Task<Void, Never>?

    /// This wallet's transactions belonging to whichever portfolio is currently active. `transactions`
    /// itself holds every portfolio's rows for the wallet (filtering here is free and avoids a
    /// disk round-trip on every portfolio switch — see `PortfolioManager`).
    var scopedTransactions: [PortfolioTransaction] {
        guard let activeId = PortfolioManager.shared.activePortfolioId else { return [] }
        return transactions.filter { $0.portfolioId == activeId }
    }

    var transactionsDescending: [PortfolioTransaction] {
        scopedTransactions.sorted { $0.timestamp > $1.timestamp }
    }

    var summary: PortfolioSummary {
        Self.computeSummary(transactions: scopedTransactions, currentPriceUsd: currentPriceUsd ?? 0)
    }

    var valueHistory: [PricePoint] {
        Self.computeValueHistory(transactions: scopedTransactions, priceHistory: priceHistory)
    }

    /// Current holdings value for a specific portfolio (not necessarily the active one) — used
    /// by the picker header to show every portfolio's card simultaneously.
    func currentValue(for portfolioId: UUID) -> Double {
        let scoped = transactions.filter { $0.portfolioId == portfolioId }
        return Self.computeSummary(transactions: scoped, currentPriceUsd: currentPriceUsd ?? 0).currentValue
    }

    /// Today's $ and % change for a specific portfolio, derived from `sevenDayPriceHistory` so
    /// it's stable regardless of the visible chart's selected range. `nil` when there isn't yet
    /// a value-history sample at least 24h old (e.g. a portfolio created today) — callers should
    /// show a neutral/no-data state rather than a misleading number.
    func todayChange(for portfolioId: UUID) -> (amount: Double, percent: Double)? {
        let scoped = transactions.filter { $0.portfolioId == portfolioId }
        let history = Self.computeValueHistory(transactions: scoped, priceHistory: sevenDayPriceHistory)
        return Self.computeTodayChange(valueHistory: history)
    }

    init(coinGecko: CoinGeckoService = .shared) {
        self.coinGecko = coinGecko
        refreshPrice()
        portfolioSwitchCancellable = PortfolioManager.shared.$activePortfolioId
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                Task { @MainActor [weak self] in
                    self?.publishWidgetSnapshot()
                }
            }
        widgetSnapshotCancellable = $transactions
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.publishWidgetSnapshot()
                }
            }
        portfolioListCancellable = PortfolioManager.shared.$portfolios
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.publishWidgetSnapshot()
                }
            }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread at runtime, but the
            // closure's type isn't provably `@MainActor` to the compiler - hop explicitly rather
            // than calling the isolated `handleSettingsChanged()` directly from here.
            Task { @MainActor in
                self?.handleSettingsChanged()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    /// Re-fetches price/history in the new currency whenever it changes - a currency switch
    /// while Portfolio is open must not just reformat the existing (wrong-currency) numbers.
    private func handleSettingsChanged() {
        let newCurrency = SettingsViewModel.loadSettings().currency
        guard newCurrency != currentCurrency else { return }
        currentCurrency = newCurrency
        refreshPrice()
    }

    /// Portfolio entries are scoped per wallet — otherwise switching wallets on this
    /// device would leak one wallet's buy/sell ledger into another's view. Mirrors
    /// ColdStorageManager.setCurrentWallet's key-per-wallet pattern. Requires
    /// `PortfolioManager.shared.setCurrentWallet` to have already run for this same wallet (see
    /// the 8 paired call sites in WalletManager.swift) so its resolved default portfolio id is
    /// ready for `PortfolioLedgerStore`'s legacy-ledger back-fill.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalizedAddress = normalizeWalletAddress(walletAddress)
        guard activeWalletAddress != normalizedAddress else { return }
        activeWalletAddress = normalizedAddress
        // A backfill pass in flight belongs to the previous wallet's ledger — stop it before
        // swapping `transactions` out from under it.
        priceBackfillTask?.cancel()
        priceBackfillTask = nil
        guard let normalizedAddress, let defaultPortfolioId = PortfolioManager.shared.portfolios.first?.id else {
            transactions = []
            return
        }
        transactions = PortfolioLedgerStore.load(walletAddress: normalizedAddress, defaultPortfolioId: defaultPortfolioId)
        // Rows left unpriced by an import the app was killed/backgrounded during (or by an older
        // build with no backfill at all) resume pricing here.
        startPriceBackfillIfNeeded()
    }

    private func normalizeWalletAddress(_ walletAddress: String?) -> String? {
        guard let walletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !walletAddress.isEmpty else {
            return nil
        }
        return walletAddress.lowercased()
    }

    /// Explicit "get current data" action: refetches the live price and clears the price
    /// history cache so every range gets refetched fresh (bypassing whatever's cached).
    func refreshPrice() {
        let currency = currentCurrency
        Task { [weak self] in
            guard let self else { return }
            if let result = await self.coinGecko.getCurrentPrice(currency: currency) {
                self.currentPriceUsd = result.price
                self.priceChange24h = result.change24hPercent
            }
            // Cold-launch path: this is the refresh MainTabView's warm-up triggers, so the
            // widget store must publish here too (refreshPriceAsync's publish only covers
            // pull-to-refresh).
            self.publishWidgetSnapshot()
        }
        cancelPriceHistoryTasks()
        priceHistoryCache.removeAll()
        fetchPriceHistory(days: priceRangeDays, force: true)
        fetchSevenDayPriceHistoryForCards()
    }

    /// Abandons every in-flight range fetch (explicit-refresh paths only - a mere range
    /// switch lets fetches complete into their caches instead). Epoch bump + removeAll means
    /// an abandoned task can neither write results nor evict a successor from the dictionary.
    private func cancelPriceHistoryTasks() {
        priceHistoryEpoch += 1
        for task in priceHistoryTasks.values { task.cancel() }
        priceHistoryTasks.removeAll()
    }

    /// Fetches (or refetches, on a currency change) the fixed 7-day window `sevenDayPriceHistory`
    /// relies on — independent of whatever range the visible chart is currently toggled to.
    /// Served from the persisted 10-minute cache when fresh enough (the cards tolerate slight
    /// staleness), and otherwise staggered behind the main chart's fetch — this call landing in
    /// the same instant as the price + chart fetches was part of the launch burst that tripped
    /// CoinGecko's keyless-tier throttle.
    private func fetchSevenDayPriceHistoryForCards() {
        let currency = currentCurrency
        if let persisted = readPersistedHistory(days: 7, currency: currency),
           Date().timeIntervalSince(persisted.fetchedAt) < Self.historyCacheTTL {
            sevenDayPriceHistory = persisted.points
            publishWidgetSnapshot()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            let result = await self.coinGecko.getPriceHistory(days: 7, currency: currency)
            guard !result.isEmpty else { return }
            self.persistHistory(result, days: 7, currency: currency)
            self.sevenDayPriceHistory = result
            self.publishWidgetSnapshot()
        }
    }

    /// Same refresh as refreshPrice(), but awaits both fetches — for pull-to-refresh, whose
    /// spinner needs to stay up until the data has actually arrived rather than returning the
    /// instant the underlying fire-and-forget Tasks are merely kicked off.
    func refreshPriceAsync() async {
        cancelPriceHistoryTasks()
        priceHistoryCache.removeAll()
        fetchSevenDayPriceHistoryForCards()
        let currency = currentCurrency
        let coinGecko = self.coinGecko
        // Capture the range this refresh is fetching - a range tap mid-refresh must not
        // mis-key the cache write or repaint the new range with the old range's data.
        let days = priceRangeDays
        async let price = coinGecko.getCurrentPrice(currency: currency)
        async let history = Self.fetchHistoryDownsampled(coinGecko, days: days, currency: currency)
        if let result = await price {
            currentPriceUsd = result.price
            priceChange24h = result.change24hPercent
        }
        let result = await history
        if !result.isEmpty {
            persistHistory(result, days: days, currency: currency)
            priceHistoryCache[days] = result
            if priceRangeDays == days {
                priceHistory = result
            }
        }
        publishWidgetSnapshot()
    }

    // MARK: - Home Screen widget snapshot

    /// Mirror of the widget extension's types - keys MUST stay in sync.
    private struct PortfolioWidgetSnapshot: Codable {
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
        /// Last-24h KAS price curve (downsampled) for the medium widget's sparkline.
        let sparkline24h: [Double]
    }

    private struct PortfolioWidgetStore: Codable {
        struct Entry: Codable {
            let id: String
            let name: String
        }
        /// Portfolio id (uuidString) -> snapshot, for the widget's per-portfolio selection.
        let snapshots: [String: PortfolioWidgetSnapshot]
        /// Portfolio list for the widget's Edit menu.
        let portfolios: [Entry]
        /// The app's currently active portfolio - the widget's default when unconfigured.
        let activeId: String?
    }

    private static func widgetCurrencySymbol(for currency: AppCurrency) -> String {
        if currency == .bitcoin { return "\u{20BF}" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        return formatter.currencySymbol ?? currency.code
    }

    /// Writes the ACTIVE portfolio's current numbers into the app group for the Home Screen
    /// widget, then asks WidgetKit to refresh. Called after every price refresh and (debounced)
    /// after any transactions change.
    func publishWidgetSnapshot() {
        guard let defaults = UserDefaults(suiteName: "group.com.kachat.app") else { return }
        let price = currentPriceUsd ?? 0
        let symbol = Self.widgetCurrencySymbol(for: currentCurrency)
        // 24h sparkline from the stable 7-day history (hourly granularity), downsampled.
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let dayPoints = sevenDayPriceHistory.filter { $0.timestamp >= dayAgo }.map(\.value)
        let stride = max(1, dayPoints.count / 40)
        let sparkline = dayPoints.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        var snapshots: [String: PortfolioWidgetSnapshot] = [:]
        var entries: [PortfolioWidgetStore.Entry] = []
        for portfolio in PortfolioManager.shared.portfolios {
            let value = currentValue(for: portfolio.id)
            let change = todayChange(for: portfolio.id)
            snapshots[portfolio.id.uuidString] = PortfolioWidgetSnapshot(
                portfolioName: portfolio.name,
                currentValue: value,
                changeAmount: change?.amount,
                changePercent: change?.percent,
                kasPrice: price,
                priceChange24hPercent: priceChange24h,
                kasUnits: price > 0 ? value / price : 0,
                currencySymbol: symbol,
                currencyCode: currentCurrency.code,
                updatedAt: Date(),
                sparkline24h: sparkline
            )
            entries.append(PortfolioWidgetStore.Entry(id: portfolio.id.uuidString, name: portfolio.name))
        }
        let store = PortfolioWidgetStore(
            snapshots: snapshots,
            portfolios: entries,
            activeId: PortfolioManager.shared.activePortfolioId?.uuidString
        )
        if let data = try? JSONEncoder().encode(store) {
            defaults.set(data, forKey: "kachat_portfolio_widget_store")
            WidgetCenter.shared.reloadTimelines(ofKind: "KaChatPortfolioWidgetV2")
        }
    }

    /// Switches the price chart's window (1D/1W/1M/3M/1Y) and paints/refetches history for it.
    /// Re-tapping the already-selected range retries a range that never managed to load
    /// (harmless no-op when its data is cached or its fetch is still in flight).
    func setPriceRangeDays(_ days: Int) {
        guard priceRangeDays != days else {
            if priceHistoryCache[days] == nil { fetchPriceHistory(days: days) }
            return
        }
        priceRangeDays = days
        fetchPriceHistory(days: days)
    }

    func cyclePriceRange() {
        let next: Int
        switch priceRangeDays {
        case 1: next = 7
        case 7: next = 30
        case 30: next = 90
        case 90: next = 365
        default: next = 1
        }
        setPriceRangeDays(next)
    }

    // MARK: - Persistent price-history cache (10-minute TTL)

    /// CoinGecko's keyless tier throttles bursts aggressively — a cold launch already costs a
    /// few calls, so cycling chart ranges could exhaust the limit and leave every new range's
    /// fetch returning empty, with the chart stuck showing the first range's ~1-day curve no
    /// matter which range was selected. Persisting each (currency, days) history for 10 minutes
    /// makes range cycling free after the first fetch (and across relaunches), and on a failed
    /// fetch the stale copy for the *requested* range still beats showing the wrong range.
    private struct CachedPriceHistory: Codable {
        let fetchedAt: Date
        let points: [PricePoint]
    }

    private static let historyCacheTTL: TimeInterval = 10 * 60

    private func historyCacheKey(days: Int, currency: AppCurrency) -> String {
        "kachat_price_history_\(currency.rawValue)_\(days)"
    }

    private func readPersistedHistory(days: Int, currency: AppCurrency) -> CachedPriceHistory? {
        guard let data = UserDefaults.standard.data(forKey: historyCacheKey(days: days, currency: currency)),
              let cached = try? JSONDecoder().decode(CachedPriceHistory.self, from: data),
              !cached.points.isEmpty else { return nil }
        return cached
    }

    private func persistHistory(_ points: [PricePoint], days: Int, currency: AppCurrency) {
        guard let data = try? JSONEncoder().encode(CachedPriceHistory(fetchedAt: Date(), points: points)) else { return }
        UserDefaults.standard.set(data, forKey: historyCacheKey(days: days, currency: currency))
    }

    /// Stale-while-refresh per range. On every tap the best data already on hand for the
    /// TAPPED range paints synchronously - session cache first, else the persisted copy even
    /// when older than the 10-minute TTL (a 3-month curve from an hour ago is still the right
    /// shape) - so switching ranges never blocks on the network. Only when this range has no
    /// data at all is `priceHistory` cleared, showing the chart card's spinner instead of the
    /// previous range's curve mislabeled as the new one. A refresh then runs behind unless the
    /// persisted copy is TTL-fresh.
    ///
    /// The refresh task is per-range and deduped: one in flight per range, never cancelled by
    /// a range switch (it completes into its own cache; see `priceHistoryTasks`). While its
    /// range stays selected it keeps retrying on a growing backoff, so a range parked by
    /// CoinGecko's keyless-tier 429 throttling loads by itself once the window clears rather
    /// than never. Completion repaints only if the range is still the one on screen.
    /// `force` (explicit refresh) skips the fresh-cache early-outs but still paints stale
    /// data first.
    private func fetchPriceHistory(days: Int, force: Bool = false) {
        let currency = currentCurrency
        if let cached = priceHistoryCache[days] {
            priceHistory = cached
            if !force { return }
        } else if let persisted = readPersistedHistory(days: days, currency: currency) {
            let points = Self.downsample(persisted.points)
            priceHistory = points
            if !force, Date().timeIntervalSince(persisted.fetchedAt) < Self.historyCacheTTL {
                priceHistoryCache[days] = points
                return
            }
        } else if priceRangeDays == days {
            priceHistory = []
        }

        guard priceHistoryTasks[days] == nil else { return }
        let epoch = priceHistoryEpoch
        priceHistoryTasks[days] = Task { [weak self] in
            guard let self else { return }
            let coinGecko = self.coinGecko
            var result: [PricePoint] = []
            // Growing pauses between attempts: CoinGecko's keyless tier 429s bursts for a
            // stretch, so a parked range needs patient retries, not a single quick one. Only
            // the range the user is still looking at earns the later retries; a range tapped
            // past gets one shot (into its cache) and stops.
            for delaySeconds in [0.0, 4.0, 12.0, 30.0] {
                if delaySeconds > 0 {
                    guard self.priceRangeDays == days else { break }
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                guard !Task.isCancelled, self.priceHistoryEpoch == epoch else { return }
                result = await Self.fetchHistoryDownsampled(coinGecko, days: days, currency: currency)
                if !result.isEmpty { break }
            }
            guard !Task.isCancelled, self.priceHistoryEpoch == epoch else { return }
            if !result.isEmpty {
                self.persistHistory(result, days: days, currency: currency)
                self.priceHistoryCache[days] = result
                if self.priceRangeDays == days {
                    self.priceHistory = result
                }
            }
            self.priceHistoryTasks[days] = nil
        }
    }

    /// Fetch + decode + downsample entirely off the main actor (nonisolated async runs on the
    /// global executor) - the 1M/3M ranges arrive at hourly granularity (~720/~2160 points)
    /// and must not be crunched on the UI thread mid range-switch.
    private nonisolated static func fetchHistoryDownsampled(
        _ coinGecko: CoinGeckoService,
        days: Int,
        currency: AppCurrency
    ) async -> [PricePoint] {
        downsample(await coinGecko.getPriceHistory(days: days, currency: currency))
    }

    /// Caps a series at ~`maxCount` points for the chart, keeping each time-bucket's min AND
    /// max samples (in order) so spikes and dips survive. Without this, the 3M range's ~2160
    /// hourly points become ~4300 catmullRom Swift Charts marks and the switch visibly hitches.
    /// 288 keeps the 1D range (5-minutely, 288 points) untouched.
    nonisolated static func downsample(_ points: [PricePoint], maxCount: Int = 288) -> [PricePoint] {
        guard maxCount >= 4, points.count > maxCount else { return points }
        let bucketCount = maxCount / 2
        let bucketSize = Double(points.count) / Double(bucketCount)
        var result: [PricePoint] = []
        result.reserveCapacity(maxCount + 2)
        for bucket in 0..<bucketCount {
            let start = Int(Double(bucket) * bucketSize)
            let end = min(Int(Double(bucket + 1) * bucketSize), points.count)
            guard start < end else { continue }
            var minPoint = points[start]
            var maxPoint = points[start]
            for point in points[start..<end] {
                if point.value < minPoint.value { minPoint = point }
                if point.value > maxPoint.value { maxPoint = point }
            }
            let pair = minPoint.timestamp <= maxPoint.timestamp ? (minPoint, maxPoint) : (maxPoint, minPoint)
            result.append(pair.0)
            if pair.1.timestamp != pair.0.timestamp { result.append(pair.1) }
        }
        // Preserve the true endpoints so the plotted latest price matches the header readout.
        if let first = points.first, result.first != first, result.first?.timestamp != first.timestamp {
            result.insert(first, at: 0)
        }
        if let last = points.last, result.last != last, result.last?.timestamp != last.timestamp {
            result.append(last)
        }
        return result
    }

    // MARK: - Ledger CRUD

    /// `sourceAddress`/`sourceTxId` are set when the row came from a real on-chain transaction
    /// (see `AddToPortfolioSheet`), so a later add of the same transaction can be recognised
    /// instead of silently double-counting it.
    func addTransaction(
        type: PortfolioTransactionType,
        amountKas: Double,
        fiatValue: Double,
        timestamp: Date,
        notes: String?,
        portfolioId: UUID? = nil,
        sourceAddress: String? = nil,
        sourceTxId: String? = nil
    ) {
        guard let activePortfolioId = portfolioId ?? PortfolioManager.shared.activePortfolioId else { return }
        let tx = PortfolioTransaction(
            id: UUID().uuidString,
            type: type,
            amountSompi: Int64((amountKas * 100_000_000).rounded()),
            fiatValue: fiatValue,
            timestamp: timestamp,
            notes: notes,
            portfolioId: activePortfolioId,
            sourceAddress: sourceAddress,
            sourceTxId: sourceTxId
        )
        transactions.append(tx)
        persist()
    }

    /// Preserves the existing row's `portfolioId` (a transaction being edited never moves to a
    /// different portfolio) rather than re-stamping with whatever's active — editing shouldn't
    /// silently reassign a row if the user switched portfolios mid-edit.
    func updateTransaction(
        id: String,
        type: PortfolioTransactionType,
        amountKas: Double,
        fiatValue: Double,
        timestamp: Date,
        notes: String?
    ) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        transactions[index] = PortfolioTransaction(
            id: id,
            type: type,
            amountSompi: Int64((amountKas * 100_000_000).rounded()),
            fiatValue: fiatValue,
            timestamp: timestamp,
            notes: notes,
            portfolioId: transactions[index].portfolioId
        )
        persist()
    }

    func deleteTransaction(id: String) {
        transactions.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        PortfolioLedgerStore.save(transactions, walletAddress: activeWalletAddress)
    }

    /// Permanently deletes this wallet's portfolio ledger, used when a saved account is
    /// removed from the device entirely. Mirrors ColdStorageManager.clearAllLocalData.
    func clearAllLocalData() {
        priceBackfillTask?.cancel()
        priceBackfillTask = nil
        PortfolioLedgerStore.save([], walletAddress: activeWalletAddress)
        transactions = []
    }

    // MARK: - CSV (CoinMarketCap "Transaction History" format)

    /// Column order matches CoinMarketCap's portfolio Transaction History export exactly:
    /// `Date (UTC±H:MM),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes`
    /// — so a file exported from CoinMarketCap imports here unmodified, and a file exported
    /// from here imports back into CoinMarketCap unmodified.
    private static let trackedToken = "KAS"

    /// CoinMarketCap formats numeric columns with thousands-separator commas above 999 (e.g.
    /// "10,597.25", "6,093,184.09"), which plain `Double(_:)` rejects outright — parsing every
    /// such row would otherwise silently fail and get skipped. Strips those before parsing.
    private static func parseLenientDouble(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
    }

    private static func makeDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }

    /// CoinMarketCap bakes the exporting user's local UTC offset into the date column's own
    /// header name (e.g. "Date (UTC-4:00)") rather than into each row, so the offset has to be
    /// parsed once from the header before any row's timestamp can be interpreted correctly.
    /// Falls back to UTC if the header doesn't look like CoinMarketCap's (or is missing).
    private static func parseHeaderUTCOffset(_ header: String) -> TimeZone {
        let utcTimeZone = TimeZone(identifier: "UTC") ?? .current
        guard let utcRange = header.range(of: "UTC", options: .caseInsensitive),
              let closeParen = header[utcRange.upperBound...].firstIndex(of: ")") else {
            return utcTimeZone
        }
        let offsetString = header[utcRange.upperBound..<closeParen]
        let parts = offsetString.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else {
            return utcTimeZone
        }
        let sign = offsetString.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (abs(hours) * 3600 + minutes * 60)) ?? utcTimeZone
    }

    /// Writes a CoinMarketCap-compatible CSV to a temp file and returns its URL for a share
    /// sheet. Rows are exported in ascending timestamp order, always in UTC (spelled out in the
    /// header) so re-importing never depends on the exporting device's local timezone. Fee /
    /// Fee Currency are written as zero/USD — the ledger doesn't keep fee as a separate line
    /// item; any fee captured at import time is already folded into Total value (USD).
    func exportCsvURL() -> URL? {
        let dateFormatter = Self.makeDateFormatter(timeZone: TimeZone(identifier: "UTC") ?? .current)
        var csv = "Date (UTC+0:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes\n"
        for tx in scopedTransactions.sorted(by: { $0.timestamp < $1.timestamp }) {
            let date = dateFormatter.string(from: tx.timestamp)
            let amount = tx.amountKas
            let price = amount != 0 ? tx.fiatValue / amount : 0
            let notes = (tx.notes ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(date)\",\"\(Self.trackedToken)\",\"\(tx.type.rawValue)\",\"\(price)\",\"\(amount)\",\"\(tx.fiatValue)\",\"0.00\",\"USD\",\"\(notes)\"\n"
        }

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("portfolio_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        let fileTimestamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = exportDir.appendingPathComponent("kachat-portfolio-\(fileTimestamp).csv")

        do {
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Parses a CoinMarketCap "Transaction History" CSV — same column order exportCsvURL
    /// writes, so real CoinMarketCap exports import here directly too. Only rows for the
    /// tracked token (KAS) are imported; other tokens in a mixed-portfolio CMC export are
    /// silently skipped, as are malformed rows and unsupported Type values (only buy/sell are
    /// tracked). Fee is folded into Total value (USD) when the fee is itself denominated in
    /// USD — added for buys, subtracted for sells — since the ledger doesn't track fee as a
    /// separate line item. A row whose timestamp exactly matches an existing transaction
    /// replaces it in place (same id, new data) rather than adding a duplicate — re-importing
    /// a corrected or re-exported CSV updates the ledger instead of piling up copies. Returns
    /// the number of rows imported or replaced.
    /// Imports into whichever portfolio is currently active. Timestamp-match-and-replace only
    /// considers that portfolio's own rows (not the whole wallet's, which may now include other
    /// portfolios' transactions) — otherwise a row could get silently reassigned or overwritten
    /// across portfolios just because two unrelated ledgers happen to share a timestamp.
    func importCsv(from url: URL) -> Int {
        guard let activePortfolioId = PortfolioManager.shared.activePortfolioId else { return 0 }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }

        var lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return 0 }
        let header = lines.removeFirst()
        let dateFormatter = Self.makeDateFormatter(timeZone: Self.parseHeaderUTCOffset(header))

        var indexByTimestamp: [Date: Int] = [:]
        for (index, tx) in transactions.enumerated() where tx.portfolioId == activePortfolioId {
            indexByTimestamp[tx.timestamp] = index
        }

        var imported = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = Self.parseCsvLine(line)
            guard fields.count >= 6 else { continue }

            let token = fields[1].trimmingCharacters(in: .whitespaces)
            guard token.caseInsensitiveCompare(Self.trackedToken) == .orderedSame else { continue }

            let typeRaw = fields[2].trimmingCharacters(in: .whitespaces).lowercased()
            guard let type = PortfolioTransactionType(rawValue: typeRaw) else { continue }
            guard let timestamp = dateFormatter.date(from: fields[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let kas = Self.parseLenientDouble(fields[4]) else { continue }
            guard let totalValue = Self.parseLenientDouble(fields[5]) else { continue }

            var fiatValue = totalValue
            if fields.count > 7 {
                let feeCurrency = fields[7].trimmingCharacters(in: .whitespaces)
                if feeCurrency.caseInsensitiveCompare("USD") == .orderedSame,
                   let fee = Self.parseLenientDouble(fields[6]) {
                    switch type {
                    case .buy: fiatValue += fee
                    case .sell: fiatValue = max(fiatValue - fee, 0)
                    }
                }
            }

            let notes = fields.count > 8 && !fields[8].isEmpty ? fields[8] : nil

            if let existingIndex = indexByTimestamp[timestamp] {
                transactions[existingIndex] = PortfolioTransaction(
                    id: transactions[existingIndex].id,
                    type: type,
                    amountSompi: Int64((kas * 100_000_000).rounded()),
                    fiatValue: fiatValue,
                    timestamp: timestamp,
                    notes: notes,
                    portfolioId: activePortfolioId
                )
            } else {
                transactions.append(
                    PortfolioTransaction(
                        id: UUID().uuidString,
                        type: type,
                        amountSompi: Int64((kas * 100_000_000).rounded()),
                        fiatValue: fiatValue,
                        timestamp: timestamp,
                        notes: notes,
                        portfolioId: activePortfolioId
                    )
                )
                indexByTimestamp[timestamp] = transactions.count - 1
            }
            imported += 1
        }

        if imported > 0 { persist() }
        return imported
    }

    /// Fetches `address`'s on-chain transaction history and adds new buy/sell rows (see
    /// `PortfolioAddressImporter`) into the active portfolio. Re-entering the same address later
    /// only adds transactions not already present for it (deduped by on-chain tx id) — same
    /// "re-run to pick up new activity" shape `importCsv` already has for a re-imported file.
    func importAddress(
        _ address: String,
        onProgress: @escaping (String) -> Void
    ) async -> Result<PortfolioAddressImporter.ImportResult, PortfolioAddressImporter.ImportError> {
        guard let activePortfolioId = PortfolioManager.shared.activePortfolioId else {
            return .failure(.noActivePortfolio)
        }
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingTxIds = Set(
            transactions
                .filter { $0.sourceAddress == normalizedAddress }
                .compactMap { $0.sourceTxId }
        )
        let result = await PortfolioAddressImporter.importAddress(
            address,
            portfolioId: activePortfolioId,
            existingTxIds: existingTxIds,
            currency: currentCurrency,
            onProgress: onProgress
        )
        if case .success(let importResult) = result {
            transactions.append(contentsOf: importResult.imported)
            persist()
            // Rows the synchronous batched pricing couldn't cover land immediately with the
            // right balance and a "price loading" note — the backfill fills their prices in
            // behind, so the import never blocks (or fails) on CoinGecko's rate limit.
            startPriceBackfillIfNeeded()
        }
        return result
    }

    // MARK: - Background price backfill

    private var hasPendingPriceRows: Bool {
        transactions.contains { PortfolioAddressImporter.isPricePending($0.notes) && $0.sourceTxId != nil }
    }

    /// Prices auto-imported rows the import itself couldn't price (batch range call failed, or
    /// the day is older than CoinGecko's keyless 365-day window). Runs a few passes on a growing
    /// backoff — each pass retries the batched range call first (cheap: cache + at most one
    /// request) and then walks the leftover days through the paced per-day fallback, saving
    /// every price the moment it lands so rows fill in incrementally rather than all-or-nothing.
    /// One loop at a time; re-triggering while it runs is a no-op (the running loop picks up any
    /// newly imported rows on its next pass).
    func startPriceBackfillIfNeeded() {
        guard priceBackfillTask == nil, hasPendingPriceRows else { return }
        let wallet = activeWalletAddress
        priceBackfillTask = Task { [weak self] in
            for delaySeconds in [0.0, 30.0, 120.0, 300.0] {
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                guard let self, !Task.isCancelled, self.activeWalletAddress == wallet,
                      self.hasPendingPriceRows else { break }
                await self.runPriceBackfillPass(wallet: wallet)
            }
            // A cancelled task must not clear the slot — wallet switch/clear already reset it,
            // possibly to a NEW task this stale one would otherwise clobber.
            guard let self, !Task.isCancelled else { return }
            self.priceBackfillTask = nil
        }
    }

    private func runPriceBackfillPass(wallet: String?) async {
        let currency = currentCurrency
        let pending = transactions.filter { PortfolioAddressImporter.isPricePending($0.notes) && $0.sourceTxId != nil }
        guard !pending.isEmpty else { return }
        let days = Array(Set(pending.map { PortfolioAddressImporter.utcDay(for: $0.timestamp) }))

        var prices = await PortfolioAddressImporter.resolveDailyPrices(for: days, currency: currency)
        // Days the batched range couldn't cover: paced per-day fallback, newest first, capped
        // per pass so one pass stays bounded (~1 minute) — the rest wait for the next pass.
        let missing = days.sorted(by: >).filter { prices[$0] == nil }
        for day in missing.prefix(30) {
            guard !Task.isCancelled, activeWalletAddress == wallet else { break }
            if let price = await PortfolioAddressImporter.resolveDailyPriceSingle(day: day, currency: currency) {
                prices[day] = price
            }
            try? await Task.sleep(nanoseconds: PortfolioAddressImporter.priceRequestSpacingNanoseconds)
        }

        guard !prices.isEmpty, !Task.isCancelled, activeWalletAddress == wallet else { return }
        var changed = false
        for index in transactions.indices {
            let tx = transactions[index]
            guard PortfolioAddressImporter.isPricePending(tx.notes), tx.sourceTxId != nil,
                  let price = prices[PortfolioAddressImporter.utcDay(for: tx.timestamp)] else { continue }
            transactions[index].fiatValue = tx.amountKas * price
            transactions[index].notes = nil
            changed = true
        }
        if changed { persist() }
    }

    /// Splits on commas outside double quotes, unescapes "" back to " within a quoted field.
    private static func parseCsvLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes, c == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                current.append("\"")
                i += 1
            } else if c == "\"" {
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: - Pure functions

    static func computeSummary(transactions: [PortfolioTransaction], currentPriceUsd: Double) -> PortfolioSummary {
        var holdingsSompi: Int64 = 0
        var totalInvested: Double = 0
        var totalProceeds: Double = 0
        var totalBoughtSompi: Int64 = 0
        for tx in transactions {
            switch tx.type {
            case .buy:
                holdingsSompi += tx.amountSompi
                totalInvested += tx.fiatValue
                totalBoughtSompi += tx.amountSompi
            case .sell:
                holdingsSompi -= tx.amountSompi
                totalProceeds += tx.fiatValue
            }
        }
        let holdingsKas = Double(holdingsSompi) / 100_000_000.0
        let currentValue = holdingsKas * currentPriceUsd
        let totalPL = (currentValue + totalProceeds) - totalInvested
        let totalPLPercent = totalInvested > 0 ? (totalPL / totalInvested) * 100.0 : 0.0
        let totalBoughtKas = Double(totalBoughtSompi) / 100_000_000.0
        let averageBuyPriceUsd = totalBoughtKas > 0 ? totalInvested / totalBoughtKas : nil
        return PortfolioSummary(
            holdingsKas: holdingsKas,
            totalInvested: totalInvested,
            totalProceeds: totalProceeds,
            currentValue: currentValue,
            totalPL: totalPL,
            totalPLPercent: totalPLPercent,
            averageBuyPriceUsd: averageBuyPriceUsd
        )
    }

    /// Replays the transaction ledger against each price-history point to get holdings *as of
    /// that moment* (not current holdings) — a buy/sell made partway through the window
    /// changes the value curve's shape from that point on, not retroactively. A transaction
    /// exactly at a price point's timestamp counts as included (strictly-greater is the break
    /// condition, matching Android).
    static func computeValueHistory(transactions: [PortfolioTransaction], priceHistory: [PricePoint]) -> [PricePoint] {
        guard !priceHistory.isEmpty else { return [] }
        let sortedTx = transactions.sorted { $0.timestamp < $1.timestamp }
        return priceHistory.map { point in
            var holdingsSompi: Int64 = 0
            for tx in sortedTx {
                if tx.timestamp > point.timestamp { break }
                switch tx.type {
                case .buy: holdingsSompi += tx.amountSompi
                case .sell: holdingsSompi -= tx.amountSompi
                }
            }
            let holdingsKas = Double(holdingsSompi) / 100_000_000.0
            return PricePoint(timestamp: point.timestamp, value: holdingsKas * point.value)
        }
    }

    /// Real today-only $ and % change (not all-time P&L) for the portfolio picker header's
    /// cards — the latest value-history sample minus whichever sample is closest to (but not
    /// after) 24h before it. `nil` when no sample exists that far back yet (e.g. a portfolio
    /// created today), so callers can show a neutral/no-data state instead of a wrong number.
    static func computeTodayChange(valueHistory: [PricePoint]) -> (amount: Double, percent: Double)? {
        guard let latest = valueHistory.last else { return nil }
        let dayAgo = latest.timestamp.addingTimeInterval(-86400)
        guard let basePoint = valueHistory.last(where: { $0.timestamp <= dayAgo }) else { return nil }
        let amount = latest.value - basePoint.value
        let percent = basePoint.value == 0 ? 0 : (amount / basePoint.value) * 100.0
        return (amount, percent)
    }
}
