import Foundation
import UIKit
import UserNotifications

/// Own-address receive notifications: alerts the user when any of the wallet's NON-chatting
/// addresses - spending-chain addresses (Manage Addresses) or watch-only cold-storage
/// addresses - receives Kaspa from an external source. These are wallet events, never chat:
/// no conversation is created, no bubble appears - just a local notification, plus a
/// persisted per-address balance baseline update so the catch-up path and the open
/// Manage Addresses / Cold Storage screens stay in sync.
///
/// Self-send filtering is the critical part - change from own payments, consolidations,
/// KNS inscription change, cold-storage withdrawals and pool payments between own addresses
/// must NOT notify. Two layers:
///   1. Fast path: the same `utxosChanged` batch carries `removed` entries for every watched
///      address the tx spends FROM - any own address there means we funded the tx ourselves.
///      Because ALL own addresses (chatting + spending + cold + reserved pool) are in the
///      watched set, virtually every self-send is caught here without a network call.
///   2. REST resolve (the classifier's own endpoint, `resolve_previous_outpoints=light`):
///      fetch the tx and check whether ANY input address is one of ours.
/// Notifications are deduped per txId (persisted, capped) and multiple outputs of one tx to
/// our addresses notify once with the summed amount.
///
/// Catch-up (app foregrounded after being away) diffs live balances against the persisted
/// baseline; increases are attributed via each address's recent transactions with the same
/// inputs-not-ours filter, falling back to a neutral "Balance increased" notification when
/// resolution fails. First run just seeds the baseline silently so enabling the feature (or
/// importing a wallet) never blasts notifications for historical funds.
///
/// Gated by Settings > Notifications > "Address Activity" (default ON) plus the master
/// notification mode. Deliberately NOT gated by Child Mode - Portfolio, Manage Addresses and
/// Cold Storage all remain available there, and these are wallet notifications, not social.
///
/// Addresses currently reserved-and-offered as fresh payment-pool receive addresses are
/// excluded from notification (payments to those DO create chat bubbles via the
/// payment_notice envelope - notifying here too would double up), but still count as "ours"
/// for the self-send input check.
@MainActor
final class AddressActivityNotifier: ObservableObject {
    static let shared = AddressActivityNotifier()
    private init() {}

    static let notificationThreadIdentifier = "address-activity"

    // MARK: - Cached own-address sets

    private var cachedWalletAddress: String?
    private var cachedNetworkKey: String = ""
    private var cachedSpendingMaxIndex: Int = -1
    private var spendingAddressSet: Set<String> = []
    private var coldFingerprint: String = ""
    /// Cold-storage address -> owning account label (for notification wording).
    private var coldLabelByAddress: [String: String] = [:]

    // MARK: - Per-tx dedupe / in-flight tracking

    /// TxIds already handled (notified OR deliberately suppressed as self-sends) - persisted
    /// per wallet so reopening the app can't re-notify what the live path already covered.
    private var handledTxIds: Set<String> = []
    private var handledTxIdOrder: [String] = []
    private var handledLoadedForWallet: String?
    private static let handledTxIdCap = 500

    private var inFlightTxIds: Set<String> = []
    private var lastCatchUpAt: Date?
    private var lastCatchUpWallet: String?

    // MARK: - Public surface

    /// Every address this feature wants in the UTXO subscription watched set: all revealed
    /// spending-chain addresses (0...max index) and every cold-storage address of every
    /// imported account. Derivation results are cached and only recomputed when the wallet,
    /// the spending max index, the cold-account set or the network changes - the first
    /// spending derivation per wallet does one seed decrypt + PBKDF2, same cost Manage
    /// Addresses already pays on open.
    func watchedOwnAddresses() -> Set<String> {
        refreshCaches()
        return spendingAddressSet.union(coldLabelByAddress.keys)
    }

    /// UserInfo key carrying the involved own addresses on a `.ownAddressUtxoActivity` post.
    static let utxoActivityAddressesKey = "addresses"

    /// Always-post internal event, deliberately separate from the user-notification decision:
    /// posts `.ownAddressUtxoActivity` (with the involved own addresses) whenever a UTXO batch
    /// touches any watched spending/cold address - including SELF-SEND change, which the
    /// notification paths suppress. `handleLiveUtxoAdditions`' fast path handles self-sends
    /// with no `.ownAddressActivity` post at all, and the whole notifier is gated by the
    /// Address Activity notification setting - so UI that must track its own change landing
    /// (the payment composer's Available pill, the address list screens) listens to THIS
    /// event instead. Not gated by `featureEnabled`.
    func postUtxoActivityEvent(
        parsed: ParsedUtxosChangedNotification,
        removedByTxId: [String: Set<String>]
    ) {
        let watched = watchedOwnAddresses()
        guard !watched.isEmpty else { return }
        var involved: Set<String> = []
        for entry in parsed.added {
            if let address = entry.address, watched.contains(address) {
                involved.insert(address)
            }
        }
        for removed in removedByTxId.values {
            involved.formUnion(removed.intersection(watched))
        }
        guard !involved.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ownAddressUtxoActivity,
            object: nil,
            userInfo: [Self.utxoActivityAddressesKey: Array(involved)]
        )
    }

    /// Live path, called from the UTXO classifier with the whole parsed batch. Collects
    /// outputs landing on own non-chatting addresses, dedupes per txId, applies the
    /// removed-set fast path, and schedules REST input resolution for the rest.
    func handleLiveUtxoAdditions(
        parsed: ParsedUtxosChangedNotification,
        removedByTxId: [String: Set<String>]
    ) {
        guard featureEnabled else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }
        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)

        let notifiable = notifiableAddressSet(walletAddress: wallet.publicAddress)
        guard !notifiable.isEmpty else { return }

        // Group outputs to our own addresses per tx so one tx paying several of our
        // addresses notifies once with the summed amount. Coinbase entries are skipped to
        // mirror the classifier (a miner pointed at a spending address would otherwise get
        // a notification per block; catch-up still reflects the balance growth).
        var hitsByTx: [String: [(address: String, amount: UInt64)]] = [:]
        for entry in parsed.added {
            guard !entry.isCoinbase, let address = entry.address else { continue }
            guard notifiable.contains(address) else { continue }
            hitsByTx[entry.transactionId, default: []].append((address, entry.amount))
        }
        guard !hitsByTx.isEmpty else { return }

        let ownAll = ownInputAddressSet(walletAddress: wallet.publicAddress)
        for (txId, hits) in hitsByTx {
            guard !handledTxIds.contains(txId), !inFlightTxIds.contains(txId) else { continue }

            // Fast path: the tx spends FROM one of our watched addresses in this same
            // batch - self-send (change, consolidation, withdrawal...), suppress silently.
            if let removed = removedByTxId[txId], !removed.isDisjoint(with: ownAll) {
                markHandled(txId: txId, wallet: wallet.publicAddress)
                Task { await self.refreshBaselines(for: Set(hits.map { $0.address }), wallet: wallet.publicAddress) }
                continue
            }

            inFlightTxIds.insert(txId)
            Task { [weak self] in
                await self?.resolveAndNotifyLive(
                    txId: txId,
                    hits: hits,
                    ownAddresses: ownAll,
                    walletAddress: wallet.publicAddress
                )
            }
        }
    }

    /// Catch-up path, run on app foreground: diff live balances of every watched address
    /// against the persisted baseline and notify for increases not attributable to our own
    /// activity. Debounced; the first run for a wallet only seeds the baseline.
    func runCatchUpIfNeeded() async {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        if let last = lastCatchUpAt,
           lastCatchUpWallet == wallet.publicAddress,
           Date().timeIntervalSince(last) < 60 {
            return
        }
        lastCatchUpAt = Date()
        lastCatchUpWallet = wallet.publicAddress

        refreshCaches()
        ensureHandledTxIdsLoaded(wallet: wallet.publicAddress)
        let watched = notifiableAddressSet(walletAddress: wallet.publicAddress)
        guard !watched.isEmpty else { return }

        // One batched balance fetch for the whole set (mirrors ColdStorageManager's
        // one-call-for-everything pattern). A network failure leaves baselines untouched so
        // nothing is silently marked as seen.
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(watched)) else {
            return
        }
        var currentBalances: [String: UInt64] = [:]
        for address in watched { currentBalances[address] = 0 }
        for utxo in utxos where currentBalances[utxo.address] != nil {
            currentBalances[utxo.address, default: 0] += utxo.amount
        }

        var baselines = loadBaselines(wallet: wallet.publicAddress)
        let isFirstRun = baselines.isEmpty
        var changed = false

        for (address, balance) in currentBalances {
            guard let previous = baselines[address] else {
                // Never-tracked address (feature install, newly revealed slot, fresh cold
                // import): seed silently - its history predates our tracking.
                baselines[address] = balance
                changed = true
                continue
            }
            if balance != previous { changed = true }
            if balance > previous, !isFirstRun, featureEnabled {
                await attributeAndNotifyIncrease(
                    address: address,
                    delta: balance - previous,
                    walletAddress: wallet.publicAddress
                )
            }
            baselines[address] = balance
        }

        if changed {
            saveBaselines(baselines, wallet: wallet.publicAddress)
            NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
        }
    }

    // MARK: - Live resolution

    private func resolveAndNotifyLive(
        txId: String,
        hits: [(address: String, amount: UInt64)],
        ownAddresses: Set<String>,
        walletAddress: String
    ) async {
        defer { inFlightTxIds.remove(txId) }

        var isSelfSend = false
        if let fullTx = await ChatService.shared.fetchKaspaFullTransaction(
            txId: txId,
            retries: 4,
            delayNs: 1_500_000_000
        ) {
            let inputAddresses = (fullTx.inputs ?? [])
                .compactMap { $0.previousOutpointAddress }
                .filter { !$0.isEmpty }
            if !inputAddresses.isEmpty {
                isSelfSend = inputAddresses.contains { ownAddresses.contains($0) }
            }
        }
        // Unresolvable txs still notify: the removed-set fast path already suppressed every
        // self-send whose inputs we watch (which is all of them), so an unknown-input tx here
        // is overwhelmingly external - missing real funds is worse than a rare duplicate.

        guard !handledTxIds.contains(txId) else { return }
        markHandled(txId: txId, wallet: walletAddress)

        if !isSelfSend {
            postReceiveNotification(hits: hits, dedupeKey: txId)
            AppLog.log("[AddressActivity] Notified external receive %@ (%d output(s) to own addresses)",
                  String(txId.prefix(12)), hits.count)
        } else {
            AppLog.log("[AddressActivity] Suppressed self-send %@ after input resolve", String(txId.prefix(12)))
        }

        await refreshBaselines(for: Set(hits.map { $0.address }), wallet: walletAddress)
        NotificationCenter.default.post(name: .ownAddressActivity, object: nil)
    }

    // MARK: - Catch-up attribution

    private func attributeAndNotifyIncrease(
        address: String,
        delta: UInt64,
        walletAddress: String
    ) async {
        let ownAll = ownInputAddressSet(walletAddress: walletAddress)
        let recentTxs = await ChatService.shared.fetchFullTransactionsPaginated(
            for: address,
            pageSize: 10,
            maxTransactions: 10
        )

        guard !recentTxs.isEmpty else {
            // Resolution failed entirely - still surface the funds, neutral wording.
            postBalanceIncreasedNotification(address: address, delta: delta)
            return
        }

        var attributedAny = false
        for tx in recentTxs {
            let toAddress = tx.outputs
                .filter { $0.scriptPublicKeyAddress == address }
                .reduce(UInt64(0)) { $0 + $1.amount }
            guard toAddress > 0 else { continue }
            if handledTxIds.contains(tx.transactionId) {
                attributedAny = true
                continue
            }
            attributedAny = true
            let inputAddresses = (tx.inputs ?? [])
                .compactMap { $0.previousOutpointAddress }
                .filter { !$0.isEmpty }
            let isSelfSend = !inputAddresses.isEmpty && inputAddresses.contains { ownAll.contains($0) }
            markHandled(txId: tx.transactionId, wallet: walletAddress)
            if !isSelfSend {
                postReceiveNotification(hits: [(address, toAddress)], dedupeKey: tx.transactionId)
            }
        }

        if !attributedAny {
            // Balance grew but none of the fetched recent txs pays this address (deep
            // history page or indexer lag) - neutral fallback rather than staying silent.
            postBalanceIncreasedNotification(address: address, delta: delta)
        }
    }

    // MARK: - Notification posting

    private func postReceiveNotification(hits: [(address: String, amount: UInt64)], dedupeKey: String) {
        guard featureEnabled else { return }
        let total = hits.reduce(UInt64(0)) { $0 + $1.amount }
        guard total > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Received \(Self.formatKas(total)) KAS"
        content.body = bodyDescribing(addresses: hits.map { $0.address })
        content.threadIdentifier = Self.notificationThreadIdentifier
        content.userInfo = ["kind": kindKey(for: hits.first?.address ?? "")]
        applySoundPreference(to: content)

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "addr-activity-\(dedupeKey)", content: content, trigger: nil)
        )
        // Also list it in the Profile notifications bell.
        Task { @MainActor in
            GlobalNotificationCenter.shared.record(id: "wallet-\(dedupeKey)", source: .wallet, title: content.title, body: content.body, timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: nil)
        }
    }

    private func postBalanceIncreasedNotification(address: String, delta: UInt64) {
        guard featureEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Balance increased by \(Self.formatKas(delta)) KAS"
        content.body = describe(address: address)
        content.threadIdentifier = Self.notificationThreadIdentifier
        content.userInfo = ["kind": kindKey(for: address)]
        applySoundPreference(to: content)

        let balId = "addr-activity-bal-\(address.suffix(12))-\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: balId, content: content, trigger: nil)
        )
        Task { @MainActor in
            GlobalNotificationCenter.shared.record(id: "wallet-\(balId)", source: .wallet, title: content.title, body: content.body, timestamp: Int64(Date().timeIntervalSince1970 * 1000), targetId: nil)
        }
    }

    private func applySoundPreference(to content: UNMutableNotificationContent) {
        let settings = AppSettings.load()
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil
        if !settings.incomingNotificationSoundEnabled,
           settings.incomingNotificationVibrationEnabled,
           UIApplication.shared.applicationState == .active {
            Haptics.impact(.light)
        }
    }

    private func bodyDescribing(addresses: [String]) -> String {
        let unique = Array(Set(addresses))
        if unique.count == 1, let only = unique.first {
            return describe(address: only)
        }
        return "\(unique.count) of your addresses"
    }

    private func describe(address: String) -> String {
        if let accountLabel = coldLabelByAddress[address] {
            return "Cold storage (\(accountLabel)) \(Self.shortAddress(address))"
        }
        return "Spending address \(Self.shortAddress(address))"
    }

    private func kindKey(for address: String) -> String {
        coldLabelByAddress[address] != nil ? "cold" : "spending"
    }

    static func shortAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return address.prefix(14) + "..." + address.suffix(6)
    }

    static func formatKas(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        var formatted = String(format: "%.8f", kas)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    // MARK: - Gating

    /// Settings > Notifications > "Address Activity" plus the master notification mode.
    /// Child Mode intentionally not consulted - wallet notifications are allowed there.
    private var featureEnabled: Bool {
        let settings = AppSettings.load()
        return settings.addressActivityNotificationsEnabled && settings.notificationMode != .disabled
    }

    // MARK: - Address set caching

    private func refreshCaches() {
        guard let wallet = WalletManager.shared.currentWallet else {
            cachedWalletAddress = nil
            cachedSpendingMaxIndex = -1
            spendingAddressSet = []
            coldFingerprint = ""
            coldLabelByAddress = [:]
            return
        }
        let network = AppSettings.load().networkType
        let networkKey = String(describing: network)
        let walletChanged = cachedWalletAddress != wallet.publicAddress || cachedNetworkKey != networkKey

        let maxIndex = WalletManager.shared.maxSpendingAddressIndex
        if walletChanged || cachedSpendingMaxIndex != maxIndex {
            spendingAddressSet = Set(WalletManager.shared.allSpendingAddresses())
            cachedSpendingMaxIndex = maxIndex
        }

        let accounts = ColdStorageManager.shared.accounts
        let fingerprint = accounts
            .map { "\($0.id.uuidString):\($0.maxAddressIndex)" }
            .joined(separator: ",")
        if walletChanged || fingerprint != coldFingerprint {
            var labelByAddress: [String: String] = [:]
            for account in accounts {
                guard let extendedKey = KaspaExtendedPublicKey(kpubString: account.kpubString) else { continue }
                for index in 0...account.maxAddressIndex {
                    if let address = try? extendedKey.receiveAddress(at: UInt32(index), network: network) {
                        labelByAddress[address] = account.label
                    }
                }
            }
            coldLabelByAddress = labelByAddress
            coldFingerprint = fingerprint
        }

        cachedWalletAddress = wallet.publicAddress
        cachedNetworkKey = networkKey
    }

    /// Addresses whose receives should NOTIFY: watched own addresses minus the chatting
    /// address (its receives are chat/payment classified) and minus currently-offered
    /// payment-pool reservation addresses (those notify through the chat's payment_notice).
    private func notifiableAddressSet(walletAddress: String) -> Set<String> {
        var set = spendingAddressSet.union(coldLabelByAddress.keys)
        set.remove(walletAddress)
        for offered in PaymentPoolStore.shared.allOfferedReservationAddresses(wallet: walletAddress) {
            set.remove(offered)
        }
        return set
    }

    /// Addresses that count as "ours" when they appear among a tx's INPUTS - superset of the
    /// notifiable set: chatting address + all spending (reserved pool addresses are
    /// spending-chain indices, so they're covered) + all cold storage.
    private func ownInputAddressSet(walletAddress: String) -> Set<String> {
        var set = spendingAddressSet.union(coldLabelByAddress.keys)
        set.insert(walletAddress)
        return set
    }

    // MARK: - Baseline persistence (UserDefaults, per wallet)

    private func baselinesKey(wallet: String) -> String {
        "kachat_addr_activity_baselines_\(wallet)"
    }

    private func handledTxIdsKey(wallet: String) -> String {
        "kachat_addr_activity_handled_txids_\(wallet)"
    }

    private func loadBaselines(wallet: String) -> [String: UInt64] {
        guard let data = UserDefaults.standard.data(forKey: baselinesKey(wallet: wallet)),
              let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveBaselines(_ baselines: [String: UInt64], wallet: String) {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        UserDefaults.standard.set(data, forKey: baselinesKey(wallet: wallet))
    }

    /// Re-fetches live balances for just-changed addresses and folds them into the persisted
    /// baseline, so the next catch-up doesn't re-detect (and re-notify) what the live path
    /// already handled.
    private func refreshBaselines(for addresses: Set<String>, wallet: String) async {
        guard !addresses.isEmpty else { return }
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(Array(addresses)) else { return }
        var balances: [String: UInt64] = [:]
        for address in addresses { balances[address] = 0 }
        for utxo in utxos where balances[utxo.address] != nil {
            balances[utxo.address, default: 0] += utxo.amount
        }
        var baselines = loadBaselines(wallet: wallet)
        for (address, balance) in balances {
            baselines[address] = balance
        }
        saveBaselines(baselines, wallet: wallet)
    }

    // MARK: - Handled-tx persistence

    private func ensureHandledTxIdsLoaded(wallet: String) {
        guard handledLoadedForWallet != wallet else { return }
        handledLoadedForWallet = wallet
        let stored = UserDefaults.standard.stringArray(forKey: handledTxIdsKey(wallet: wallet)) ?? []
        handledTxIdOrder = stored
        handledTxIds = Set(stored)
    }

    private func markHandled(txId: String, wallet: String) {
        ensureHandledTxIdsLoaded(wallet: wallet)
        guard handledTxIds.insert(txId).inserted else { return }
        handledTxIdOrder.append(txId)
        if handledTxIdOrder.count > Self.handledTxIdCap {
            let overflow = handledTxIdOrder.count - Self.handledTxIdCap
            for dropped in handledTxIdOrder.prefix(overflow) {
                handledTxIds.remove(dropped)
            }
            handledTxIdOrder.removeFirst(overflow)
        }
        UserDefaults.standard.set(handledTxIdOrder, forKey: handledTxIdsKey(wallet: wallet))
    }
}

extension Notification.Name {
    /// Posted after own-address (spending / cold-storage) balances changed due to detected
    /// receive activity - open Manage Addresses / Cold Storage screens reload on it.
    static let ownAddressActivity = Notification.Name("ownAddressActivity")
    /// Always-posted internal event for ANY UTXO activity on watched own addresses - including
    /// self-send change that never produces an `.ownAddressActivity` post (fast-path suppression)
    /// and regardless of the Address Activity notification setting. UserInfo carries the
    /// involved addresses under `AddressActivityNotifier.utxoActivityAddressesKey`.
    static let ownAddressUtxoActivity = Notification.Name("ownAddressUtxoActivity")
}
