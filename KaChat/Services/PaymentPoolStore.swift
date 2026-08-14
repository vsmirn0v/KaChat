import Foundation

/// Device-local persistence for the fresh-address payment pool feature (see MESSAGING.md,
/// "Fresh-Address Payment Pools", and `ChatService+PaymentPools` for the protocol logic).
///
/// Two directions of state, both scoped per wallet (keyed by the wallet's chatting address, the
/// same per-wallet UserDefaults scoping `WalletManager+SpendingAddresses` uses):
///
/// - **My reservations**: spending-chain addresses THIS wallet revealed and offered to a specific
///   contact so that contact can pay us privately. CRITICAL INVARIANT: an address reserved for
///   contact X is never offered to any other contact and never re-offered - reservations are
///   recorded here per contact, and `WalletManager.reserveFreshSpendingAddresses` only ever hands
///   out indices past the all-time max, so the two together make double-offering impossible.
/// - **Their pools**: addresses a contact shared with us via `addr_pool` - "addresses I can pay
///   this contact at". Each is single-use: consumed (marked used) when a payment send selects it.
///
/// This state is intentionally device-local (NOT CloudKit-synced): a restore onto a new device
/// simply loses it, and the apps re-exchange pools - re-offering is safe because the initial
/// offer always uses `replace: true`.
@MainActor
final class PaymentPoolStore {
    static let shared = PaymentPoolStore()

    /// How many fresh addresses each `addr_pool` offer contains.
    static let offerBatchSize = 5
    /// Send an `addr_pool_request` when the unused remainder of a contact's pool drops to this or lower.
    static let lowWaterMark = 2
    /// Reject received pools that would grow a contact's stored pool beyond this.
    static let maxStoredPoolSize = 20
    /// Cap on the remembered handled-envelope txId list (replay guard).
    private static let maxHandledTxIds = 500
    /// Minimum spacing between `addr_pool_request` sends to the same contact.
    private static let requestThrottleSeconds: TimeInterval = 10 * 60

    struct ReservedAddress: Codable, Equatable {
        let address: String
        let index: Int
        /// True once the addr_pool envelope carrying this address was actually submitted.
        var offered: Bool
    }

    struct TheirPoolAddress: Codable, Equatable {
        let address: String
        var used: Bool
    }

    private struct State: Codable {
        /// contactAddress -> my reserved spending addresses offered to that contact.
        var myReservations: [String: [ReservedAddress]] = [:]
        /// contactAddress -> that contact's fresh addresses I can pay them at.
        var theirPools: [String: [TheirPoolAddress]] = [:]
        /// Contacts we have already sent our initial pool to (the lazy once-per-contact offer marker).
        var offeredContacts: Set<String> = []
        /// Envelope txIds already processed - guards against history re-fetch replaying an
        /// addr_pool/addr_pool_request/payment_notice and re-triggering its side effects.
        /// Ordered oldest-first so capping drops the oldest.
        var handledEnvelopeTxIds: [String] = []
        /// contactAddress -> last time we sent addr_pool_request (throttle).
        var lastPoolRequestAt: [String: Date] = [:]
    }

    /// Payment-destination memory for in-flight sends, keyed by the payment's pending txId so a
    /// retry reuses the pool address already consumed for that payment instead of burning another
    /// one. Deliberately in-memory only: after an app restart a retried payment just consumes a
    /// fresh pool address, which is safe (addresses are never reused, only occasionally skipped).
    private var pendingPaymentDestinations: [String: String] = [:]

    /// Cache of the loaded state per wallet, so every query isn't a decode round trip.
    private var cachedState: [String: State] = [:]

    private init() {}

    // MARK: - Persistence

    private func defaultsKey(for walletAddress: String) -> String {
        "kachat_payment_pool_state_\(walletAddress)"
    }

    private func state(for walletAddress: String) -> State {
        if let cached = cachedState[walletAddress] {
            return cached
        }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(for: walletAddress)),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else {
            let empty = State()
            cachedState[walletAddress] = empty
            return empty
        }
        cachedState[walletAddress] = decoded
        return decoded
    }

    private func save(_ state: State, for walletAddress: String) {
        cachedState[walletAddress] = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(for: walletAddress))
    }

    // MARK: - Offer marker

    func hasOfferedPool(to contactAddress: String, wallet walletAddress: String) -> Bool {
        state(for: walletAddress).offeredContacts.contains(contactAddress)
    }

    func markPoolOffered(to contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        current.offeredContacts.insert(contactAddress)
        save(current, for: walletAddress)
    }

    // MARK: - My reservations (addresses I offered so a contact can pay ME)

    func recordMyReservations(
        _ entries: [ReservedAddress],
        for contactAddress: String,
        wallet walletAddress: String
    ) {
        guard !entries.isEmpty else { return }
        var current = state(for: walletAddress)
        var existing = current.myReservations[contactAddress] ?? []
        let known = Set(existing.map(\.address))
        existing.append(contentsOf: entries.filter { !known.contains($0.address) })
        current.myReservations[contactAddress] = existing
        save(current, for: walletAddress)
    }

    /// Reservations recorded for `contactAddress` whose addr_pool send never succeeded - a
    /// retried offer re-uses these before revealing new indices.
    func unofferedReservations(for contactAddress: String, wallet walletAddress: String) -> [ReservedAddress] {
        (state(for: walletAddress).myReservations[contactAddress] ?? []).filter { !$0.offered }
    }

    /// Flips the given reservations to offered once their addr_pool envelope was submitted.
    func markReservationsOffered(_ addresses: [String], for contactAddress: String, wallet walletAddress: String) {
        guard !addresses.isEmpty else { return }
        var current = state(for: walletAddress)
        guard var entries = current.myReservations[contactAddress] else { return }
        let target = Set(addresses)
        for index in entries.indices where target.contains(entries[index].address) {
            entries[index].offered = true
        }
        current.myReservations[contactAddress] = entries
        save(current, for: walletAddress)
    }

    /// Every reserved-and-offered address across all contacts - these belong in the UTXO
    /// subscription watched set so incoming pool payments are noticed promptly.
    func allOfferedReservationAddresses(wallet walletAddress: String) -> [String] {
        state(for: walletAddress).myReservations.values
            .flatMap { $0 }
            .filter(\.offered)
            .map(\.address)
    }

    /// True if `address` is reserved (for ANY contact) by this wallet - used both for the
    /// self-address rejection check on received pools and as the pool-logic-side "not free for
    /// other uses" marker.
    func isReservedAddress(_ address: String, wallet walletAddress: String) -> Bool {
        state(for: walletAddress).myReservations.values.contains { entries in
            entries.contains { $0.address == address }
        }
    }

    // MARK: - Their pools (addresses I can pay a contact at)

    /// Merges a received `addr_pool` into the stored pool for `contactAddress`.
    /// `replace == true` discards the previous pool (carrying over `used` flags for any address
    /// that reappears, so a replayed/overlapping replace can never resurrect a spent address);
    /// otherwise appends, deduped. The stored pool is capped at `maxStoredPoolSize` - excess
    /// entries beyond the cap are dropped, oldest kept first.
    func mergeTheirPool(
        addresses: [String],
        replace: Bool,
        for contactAddress: String,
        wallet walletAddress: String
    ) {
        var current = state(for: walletAddress)
        let existing = current.theirPools[contactAddress] ?? []
        let usedByAddress = Dictionary(existing.map { ($0.address, $0.used) }, uniquingKeysWith: { $0 || $1 })

        var merged: [TheirPoolAddress]
        if replace {
            merged = []
        } else {
            merged = existing
        }
        var seen = Set(merged.map(\.address))
        for address in addresses {
            guard !seen.contains(address) else { continue }
            seen.insert(address)
            merged.append(TheirPoolAddress(address: address, used: usedByAddress[address] ?? false))
        }
        if merged.count > Self.maxStoredPoolSize {
            merged = Array(merged.prefix(Self.maxStoredPoolSize))
        }
        current.theirPools[contactAddress] = merged
        save(current, for: walletAddress)
    }

    func hasPool(for contactAddress: String, wallet walletAddress: String) -> Bool {
        !(state(for: walletAddress).theirPools[contactAddress] ?? []).isEmpty
    }

    func unusedPoolCount(for contactAddress: String, wallet walletAddress: String) -> Int {
        (state(for: walletAddress).theirPools[contactAddress] ?? []).filter { !$0.used }.count
    }

    func nextUnusedPoolAddress(for contactAddress: String, wallet walletAddress: String) -> String? {
        (state(for: walletAddress).theirPools[contactAddress] ?? []).first { !$0.used }?.address
    }

    /// Marks a pool address consumed. Persisted immediately - a consumed address is never
    /// offered to a payment again, even if that payment ultimately fails (burning an address is
    /// safe; reusing one is not).
    func markPoolAddressUsed(_ address: String, for contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard var pool = current.theirPools[contactAddress],
              let index = pool.firstIndex(where: { $0.address == address }) else { return }
        pool[index].used = true
        current.theirPools[contactAddress] = pool
        save(current, for: walletAddress)
    }

    // MARK: - Replay guard

    func isEnvelopeHandled(txId: String, wallet walletAddress: String) -> Bool {
        state(for: walletAddress).handledEnvelopeTxIds.contains(txId)
    }

    func markEnvelopeHandled(txId: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard !current.handledEnvelopeTxIds.contains(txId) else { return }
        current.handledEnvelopeTxIds.append(txId)
        if current.handledEnvelopeTxIds.count > Self.maxHandledTxIds {
            current.handledEnvelopeTxIds.removeFirst(current.handledEnvelopeTxIds.count - Self.maxHandledTxIds)
        }
        save(current, for: walletAddress)
    }

    // MARK: - Request throttle

    func shouldRequestMoreAddresses(from contactAddress: String, wallet walletAddress: String) -> Bool {
        let current = state(for: walletAddress)
        guard !(current.theirPools[contactAddress] ?? []).isEmpty else { return false }
        guard unusedPoolCount(for: contactAddress, wallet: walletAddress) <= Self.lowWaterMark else { return false }
        if let last = current.lastPoolRequestAt[contactAddress],
           Date().timeIntervalSince(last) < Self.requestThrottleSeconds {
            return false
        }
        return true
    }

    func recordPoolRequestSent(to contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        current.lastPoolRequestAt[contactAddress] = Date()
        save(current, for: walletAddress)
    }

    // MARK: - In-flight payment destinations (in-memory)

    func rememberPaymentDestination(_ address: String, pendingTxId: String) {
        pendingPaymentDestinations[pendingTxId] = address
    }

    func paymentDestination(forPendingTxId pendingTxId: String) -> String? {
        pendingPaymentDestinations[pendingTxId]
    }

    func forgetPaymentDestination(pendingTxId: String) {
        pendingPaymentDestinations.removeValue(forKey: pendingTxId)
    }
}
