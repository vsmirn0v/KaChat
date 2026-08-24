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

    // MARK: Inbound abuse limits (part of the protocol contract - see MESSAGING.md)

    /// Serve at most one addr_pool send (top-up reply, reciprocity, or initial offer) per
    /// contact per this interval - a malicious contact spamming addr_pool_request must not be
    /// able to make us pay a tx fee per request.
    static let poolServeThrottleSeconds: TimeInterval = 10 * 60
    /// Transition-aware minimum gap for TOGGLE-driven broadcasts (revoke on OFF, re-offer on
    /// ON): a deliberate state change always propagates promptly, so it only has to clear this
    /// much smaller spacing since the previous broadcast to the same contact - the full
    /// 10-minute throttle above would silently swallow a quick off->on for up to 10 minutes.
    /// Rapid flapping stays bounded to one broadcast per contact per this gap; repeated
    /// same-state sends (organic offers, top-ups, reciprocity) keep the 10-minute throttle.
    static let toggleTransitionGapSeconds: TimeInterval = 60
    /// Hard lifetime cap on addresses ever reserved for a single contact - bounds how much of
    /// our future address space one contact can enumerate.
    static let maxLifetimeReservationsPerContact = 50
    /// Stop serving top-ups once this many offered addresses are outstanding without ever
    /// having received funds (funded knowledge comes from payment_notice envelopes naming one
    /// of our reservations - a best-effort proxy, backstopped by the lifetime cap + throttle).
    static let maxOutstandingUnfundedOffers = 15

    struct ReservedAddress: Codable, Equatable {
        let address: String
        let index: Int
        /// True once the addr_pool envelope carrying this address was actually submitted.
        /// HISTORICAL - never cleared: offered-ever addresses stay watched and payment_notice
        /// renderable forever (a payment racing any kind of revoke must still land and render).
        var offered: Bool
        /// True once a payment_notice from the contact named this address as a payment
        /// destination - optional so states persisted before this field decode fine.
        var funded: Bool?
        /// True while this address is part of the contact's CURRENT live pool - the set that
        /// drives the "Chat privacy address" tag and the can't-hide lock. Cleared (reverted)
        /// when: we revoke via the Chats Privacy toggle, the contact revokes at us, a
        /// replace:true re-offer supersedes it, or a payment_notice marks it funded. Distinct
        /// from `offered` (historical, above). Optional for decode compat: nil (pre-split
        /// state) is interpreted as offered && !funded && contact-not-revoked-by-us.
        var activeOffer: Bool?
        /// True once Generate reclaimed this reverted reservation as a personal fresh address.
        /// Reclaimed entries are never re-offered to their original contact on a privacy
        /// re-enable (the address is no longer promised to anyone); the entry itself stays,
        /// so watching and payment_notice rendering keep covering it.
        var reclaimed: Bool?
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
        /// contactAddress -> last time we SERVED an addr_pool send to that contact (inbound
        /// abuse throttle). Optional so states persisted before this field decode fine.
        var lastPoolServeAt: [String: Date]? = nil
        /// Contacts whose pool of OUR addresses we revoked (empty replace:true sent) when
        /// Chats Privacy was turned off. Cleared per contact when we next successfully offer
        /// (and wholesale on toggle-on). Optional for decode compat.
        var revokedContacts: Set<String>? = nil
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

    /// Flips the given reservations to offered (historical) and ACTIVE once their addr_pool
    /// envelope was submitted. `replace: true` means the envelope carried replace semantics -
    /// the batch IS the contact's whole live pool now, so any other reservation for this
    /// contact still flagged active is superseded and reverts to a normal address (its
    /// historical `offered` flag is untouched: it stays watched and notice-renderable).
    func markReservationsOffered(_ addresses: [String], for contactAddress: String, wallet walletAddress: String, replace: Bool) {
        guard !addresses.isEmpty else { return }
        var current = state(for: walletAddress)
        guard var entries = current.myReservations[contactAddress] else { return }
        let target = Set(addresses)
        for index in entries.indices {
            if target.contains(entries[index].address) {
                entries[index].offered = true
                entries[index].activeOffer = true
            } else if replace {
                entries[index].activeOffer = false
            }
        }
        current.myReservations[contactAddress] = entries
        save(current, for: walletAddress)
    }

    func lifetimeReservationCount(for contactAddress: String, wallet walletAddress: String) -> Int {
        (state(for: walletAddress).myReservations[contactAddress] ?? []).count
    }

    /// Reservations for `contactAddress` that can be (re-)offered in a `replace:true` batch:
    /// everything never funded, whether or not it was offered before. Used by the re-offer path
    /// (after a Chats Privacy revoke) so toggling the feature off and on doesn't burn five new
    /// indices per cycle - the contact discarded these on revoke, they're still reserved for
    /// this contact alone, and never-funded means re-offering them creates no address reuse.
    func reofferableReservations(for contactAddress: String, wallet walletAddress: String) -> [ReservedAddress] {
        (state(for: walletAddress).myReservations[contactAddress] ?? []).filter { $0.funded != true && $0.reclaimed != true }
    }

    /// Generate recycled a reverted reservation for personal use: mark it reclaimed so no
    /// re-offer path ever hands it back to its original contact. No-op for addresses that
    /// were never reservations.
    func markReclaimed(address: String, wallet walletAddress: String) {
        var s = state(for: walletAddress)
        var changed = false
        for (contact, entries) in s.myReservations {
            var updated = entries
            for i in updated.indices where updated[i].address == address && updated[i].reclaimed != true {
                updated[i].reclaimed = true
                updated[i].activeOffer = false
                changed = true
            }
            if changed { s.myReservations[contact] = updated }
        }
        if changed { save(s, for: walletAddress) }
    }

    // MARK: - Revocation lifecycle (Chats Privacy toggle)

    /// Contacts currently holding a live pool of OUR addresses - the target list for the
    /// toggle-off revoke broadcast. Derived from PERSISTED state two ways and unioned, so a
    /// contact can never dodge a revoke through marker drift: the offered-marker set AND every
    /// contact with at least one reservation actually flagged offered (both are persisted in
    /// the same per-wallet blob and normally agree; the union is belt-and-suspenders). Minus
    /// already-revoked contacts.
    func contactsHoldingOurPool(wallet walletAddress: String) -> [String] {
        let current = state(for: walletAddress)
        let revoked = current.revokedContacts ?? []
        var holders = current.offeredContacts
        for (contactAddress, entries) in current.myReservations where entries.contains(where: { $0.offered }) {
            holders.insert(contactAddress)
        }
        return holders.filter { !revoked.contains($0) }.sorted()
    }

    /// Contacts with ANY prior pool history (reservations recorded, offered marker, or a
    /// standing revocation) - used by the toggle-ON proactive re-offer to find everyone who may
    /// believe our pool is gone. Established-conversation filtering happens at the caller.
    func contactsWithPoolHistory(wallet walletAddress: String) -> Set<String> {
        let current = state(for: walletAddress)
        var contacts = current.offeredContacts
        contacts.formUnion(current.myReservations.keys)
        contacts.formUnion(current.revokedContacts ?? [])
        return contacts
    }

    func isPoolRevoked(for contactAddress: String, wallet walletAddress: String) -> Bool {
        (state(for: walletAddress).revokedContacts ?? []).contains(contactAddress)
    }

    /// Records a successful revoke: the contact no longer holds our pool, so the offered marker
    /// clears too - that's what lets the normal lazy offer re-fire after the toggle comes back
    /// on. The reservations themselves stay recorded and historically offered (still reserved
    /// for this contact only, still watched - a payment racing the revoke must land and
    /// render), but they leave the ACTIVE set: their rows revert to normal, hideable,
    /// untagged addresses until a re-offer reactivates them.
    func markPoolRevoked(for contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        var revoked = current.revokedContacts ?? []
        revoked.insert(contactAddress)
        current.revokedContacts = revoked
        current.offeredContacts.remove(contactAddress)
        if var entries = current.myReservations[contactAddress] {
            for index in entries.indices { entries[index].activeOffer = false }
            current.myReservations[contactAddress] = entries
        }
        save(current, for: walletAddress)
    }

    /// The contact revoked at us (incoming empty replace:true addr_pool): our offers to them
    /// leave the ACTIVE set - tag and hide-lock drop - without touching any protocol state
    /// (offered marker, revokedContacts, throttles), so the normal offer lifecycle is
    /// unaffected. Historical `offered` stays set: the addresses remain watched and a
    /// payment_notice naming one still renders.
    func markOffersInactive(for contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard var entries = current.myReservations[contactAddress],
              entries.contains(where: { $0.activeOffer != false }) else { return }
        for index in entries.indices { entries[index].activeOffer = false }
        current.myReservations[contactAddress] = entries
        save(current, for: walletAddress)
    }

    /// Cleared when we next successfully offer to this contact.
    func clearPoolRevocation(for contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard var revoked = current.revokedContacts, revoked.contains(contactAddress) else { return }
        revoked.remove(contactAddress)
        current.revokedContacts = revoked
        save(current, for: walletAddress)
    }

    /// Toggle-on housekeeping: forget all revocations so the lazy offers are unencumbered.
    func clearAllPoolRevocations(wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard let revoked = current.revokedContacts, !revoked.isEmpty else { return }
        current.revokedContacts = []
        save(current, for: walletAddress)
    }

    /// Gate for EVERY addr_pool send to `contactAddress` (initial offer, reciprocity, and
    /// request-driven top-ups alike): one send per contact per `poolServeThrottleSeconds`, and
    /// nothing once the lifetime reservation cap or the outstanding-unfunded-offers cap is hit.
    /// These limits are part of the protocol contract (MESSAGING.md) - they bound how much
    /// address enumeration and how many fee-costing on-chain replies a malicious contact
    /// spamming addr_pool_request (or replaying varied addr_pool envelopes) can extract.
    ///
    /// `toggleTransition: true` (a genuine Chats Payment Privacy state change) swaps the
    /// 10-minute throttle for the much smaller `toggleTransitionGapSeconds` so deliberate
    /// toggles always propagate promptly; the reservation caps still apply in full.
    func canServePoolOffer(to contactAddress: String, wallet walletAddress: String, toggleTransition: Bool = false) -> Bool {
        guard !isWithinPoolServeGap(for: contactAddress, wallet: walletAddress, toggleTransition: toggleTransition) else {
            return false
        }
        let reservations = state(for: walletAddress).myReservations[contactAddress] ?? []
        guard reservations.count < Self.maxLifetimeReservationsPerContact else { return false }
        let outstandingUnfunded = reservations.filter { $0.offered && $0.funded != true }.count
        guard outstandingUnfunded < Self.maxOutstandingUnfundedOffers else { return false }
        return true
    }

    /// Pure spacing check against the last addr_pool broadcast (offer OR revoke - both stamp
    /// `lastPoolServeAt`) to this contact: the 60s transition gap for toggle-driven sends, the
    /// full 10-minute throttle otherwise. Split out because revokes bypass the reservation caps
    /// (a revoke must always be allowed to go out) but still honor the flap-bounding gap.
    func isWithinPoolServeGap(for contactAddress: String, wallet walletAddress: String, toggleTransition: Bool) -> Bool {
        guard let last = state(for: walletAddress).lastPoolServeAt?[contactAddress] else { return false }
        let gap = toggleTransition ? Self.toggleTransitionGapSeconds : Self.poolServeThrottleSeconds
        return Date().timeIntervalSince(last) < gap
    }

    func recordPoolOfferServed(to contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        var serveMap = current.lastPoolServeAt ?? [:]
        serveMap[contactAddress] = Date()
        current.lastPoolServeAt = serveMap
        save(current, for: walletAddress)
    }

    /// Marks one of our reservations for `contactAddress` as funded - called when a
    /// payment_notice from that contact names the address as its payment destination. Feeds the
    /// outstanding-unfunded-offers cap; no-op if the address isn't one of our reservations.
    func markReservationFunded(_ address: String, for contactAddress: String, wallet walletAddress: String) {
        var current = state(for: walletAddress)
        guard var entries = current.myReservations[contactAddress],
              let index = entries.firstIndex(where: { $0.address == address }) else { return }
        guard entries[index].funded != true else { return }
        entries[index].funded = true
        // Consumed: the address leaves the ACTIVE offered set - the row is governed by the
        // funded rule from here (un-hideable via its balance, no longer tagged as an offer).
        entries[index].activeOffer = false
        current.myReservations[contactAddress] = entries
        save(current, for: walletAddress)
    }

    /// The spending-chain index of one of our reservations, by address — used to keep offered
    /// and funded reservation addresses visible in Manage Addresses (including repairing state
    /// left hidden by the old born-hidden design).
    func reservationIndex(for address: String, wallet walletAddress: String) -> Int? {
        state(for: walletAddress).myReservations.values
            .flatMap { $0 }
            .first { $0.address == address }?
            .index
    }

    /// HISTORICAL: every address ever reserved-and-offered, across all contacts, regardless of
    /// later revokes/supersedes/funding. This is the watch-and-render mapping: it belongs in
    /// the UTXO subscription watched set (a payment racing any revoke must be noticed) and in
    /// AddressActivityNotifier's pool-suppression set (those receives notify through the
    /// chat's payment_notice, never as a generic wallet notification). Never shrinks. UI
    /// tagging/locking uses `activeOfferedReservationAddresses` instead.
    func allOfferedReservationAddresses(wallet walletAddress: String) -> [String] {
        state(for: walletAddress).myReservations.values
            .flatMap { $0 }
            .filter(\.offered)
            .map(\.address)
    }

    /// ACTIVE: only the addresses currently offered in a live pool - this narrower set drives
    /// the "Chat privacy address" tag, the Address Visibility lock, the row-menu Hide
    /// suppression, the persistence-layer hide refusal, and Generate's recycling exclusion.
    /// An address leaves it when we revoke (Chats Privacy off), the contact revokes at us, a
    /// replace:true re-offer supersedes it, or it gets funded - after which its row is a
    /// normal address again. Entries persisted before the active/historical split (activeOffer
    /// == nil) fall back to offered && never funded && contact not revoked by us, which is
    /// exactly what "active" meant then.
    func activeOfferedReservationAddresses(wallet walletAddress: String) -> [String] {
        let current = state(for: walletAddress)
        let revoked = current.revokedContacts ?? []
        return current.myReservations.flatMap { contactAddress, entries in
            entries
                .filter { $0.activeOffer ?? ($0.offered && $0.funded != true && !revoked.contains(contactAddress)) }
                .map(\.address)
        }
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
