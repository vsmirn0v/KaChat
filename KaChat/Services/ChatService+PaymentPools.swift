import Foundation
import CryptoKit

// MARK: - Fresh-address payment pools
//
// Protocol logic for the privacy feature documented in MESSAGING.md ("Fresh-Address Payment
// Pools"): contacts exchange batches of fresh, never-used spending-chain receive addresses
// through the normal encrypted contextual channel (`addr_pool`), Send Kaspa pays one of those
// instead of the contact's chatting address, and a `payment_notice` envelope keeps the
// recipient's chat showing a payment bubble (their payment detection only watches the chatting
// address). All three envelope types are invisible - intercepted in
// `addMessageToConversation` before they could ever render, exactly like reactions.
// Persistent state lives in `PaymentPoolStore` (device-local, per wallet).

extension ChatService {

    // MARK: - Offering our pool

    /// Lazily offers this wallet's fresh receive addresses to `contactAddress`, once per contact
    /// (persisted marker) - called from `enterConversation`. Only fires for an established
    /// two-way conversation (at least one incoming and one outgoing message), since sending the
    /// envelope needs handshake routing anyway and a pool offered to a stranger is wasted.
    func offerAddressPoolIfNeeded(to contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        // Per-account Chats Privacy toggle (Settings > Chats): while OFF this account stops
        // sharing fresh addresses (contacts fall back to our chatting address once their stored
        // pool of ours runs out). Also covers the reciprocity path, which routes through here.
        guard AppSettings.chatsPrivacyEnabled(for: wallet.publicAddress) else { return }
        guard !PaymentPoolStore.shared.hasOfferedPool(to: contactAddress, wallet: wallet.publicAddress) else { return }
        guard PaymentPoolStore.shared.canServePoolOffer(to: contactAddress, wallet: wallet.publicAddress) else { return }
        guard isPoolEstablishedConversation(contactAddress) else { return }
        guard let contact = contactsManager.getContact(byAddress: contactAddress) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Serialized with payments/messages: reservation reads-and-bumps the spending-chain
            // max index, and `sendPaymentInternal` computes its fresh change index from that same
            // max - interleaving the two could land payment change on a reserved address.
            try? await self.enqueueOutgoingTxOperation {
                try await self.reserveAndSendAddressPool(to: contact, replace: true)
            }
        }
    }

    /// Reserves fresh spending-chain addresses for `contact` and sends them as an `addr_pool`
    /// envelope. Re-uses any reservation recorded for this contact whose send previously failed
    /// (offered == false) before revealing new indices, so a retried offer doesn't burn another
    /// batch of slots. On success the reservations flip to offered, the once-per-contact marker is set,
    /// and the UTXO subscription is rebuilt so incoming pool payments are noticed promptly.
    ///
    /// `replace: true` for the initial/lazy offer (safe re-offer semantics after a device
    /// restore - the fresh device's list is authoritative); `replace: false` for request-driven
    /// top-ups (recipient appends, deduped). `toggleTransition: true` marks a Chats Payment
    /// Privacy toggle-ON broadcast: the 60s transition gap applies instead of the full
    /// 10-minute serve throttle (reservation caps unchanged), so flipping the switch always
    /// propagates promptly. `replenish: true` marks an automatic pool-of-2 top-up triggered by
    /// a reservation getting funded: it shares the toggle broadcasts' throttle exemption
    /// (60s gap instead of the 10-minute throttle, reservation caps in full - the same shape
    /// as the revokes' cap exemption, documented in MESSAGING.md) and sends only the SHORTFALL
    /// - enough new addresses that the contact again holds `offerBatchSize` fresh ones -
    /// recomputed here inside the serialized operation so several queued triggers for the same
    /// funding collapse into one send (or none).
    func reserveAndSendAddressPool(to contact: Contact, replace: Bool, toggleTransition: Bool = false, replenish: Bool = false) async throws {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let store = PaymentPoolStore.shared

        // Re-checked INSIDE the serialized operation, not just at the call sites: several
        // envelope handlers can queue offers for the same contact before the first one runs
        // (e.g. an attacker replaying varied addr_pool envelopes to trigger reciprocity, each
        // with a distinct txId that passes the replay guard) - the marker/throttle only flip
        // once a send actually happens, so the check must happen after the queue serializes us.
        // Chats Privacy may have been toggled OFF between enqueue and execution.
        guard AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
        if replace {
            guard !store.hasOfferedPool(to: contact.address, wallet: walletAddress) else { return }
        }
        // Replenish top-ups bypass the 10-minute serve throttle (a funded reservation means
        // genuine pool usage, not a re-offer) but still honor the 60s gap and both reservation
        // caps - same exemption shape as the toggle broadcasts.
        guard store.canServePoolOffer(to: contact.address, wallet: walletAddress, toggleTransition: toggleTransition || replenish) else {
            AppLog.log("[ChatService] Pool offer to %@ suppressed by serve throttle/caps",
                       String(contact.address.suffix(10)))
            return
        }

        // Replenish sends only the shortfall back up to the target pool size; everything else
        // sends a full batch. Recomputed here (inside the serialized operation) so stacked
        // replenish triggers see the already-recorded top-up and no-op.
        let batchLimit: Int
        if replenish {
            // Their revoke may have landed between enqueue and execution - re-check here,
            // inside the serialized operation, like the other guards.
            guard !store.didContactRevokeAtUs(contact.address, wallet: walletAddress) else { return }
            let activeFresh = store.activeFreshReservationCount(for: contact.address, wallet: walletAddress)
            batchLimit = PaymentPoolStore.offerBatchSize - activeFresh
            guard batchLimit > 0 else { return }
        } else {
            batchLimit = PaymentPoolStore.offerBatchSize
        }

        // replace:true (initial offer or post-revoke re-offer) may re-send previously offered
        // but never-funded reservations - the recipient's pool was empty/discarded, re-sending
        // creates no reuse, and it keeps a toggle off/on cycle from burning a fresh batch of
        // indices against the lifetime cap every time. Append top-ups only ever send
        // never-yet-offered addresses (the recipient dedupes, but resending their live pool
        // would be waste).
        var pending = replace
            ? store.reofferableReservations(for: contact.address, wallet: walletAddress)
            : store.unofferedReservations(for: contact.address, wallet: walletAddress)
        if pending.count > batchLimit {
            pending = Array(pending.prefix(batchLimit))
        }
        // Never reserve past the per-contact lifetime cap, even mid-batch.
        let lifetimeHeadroom = PaymentPoolStore.maxLifetimeReservationsPerContact
            - store.lifetimeReservationCount(for: contact.address, wallet: walletAddress)
        let missing = min(batchLimit - pending.count, lifetimeHeadroom)
        if missing > 0 {
            let fresh = await WalletManager.shared.reserveFreshSpendingAddresses(count: missing)
            guard !fresh.isEmpty else {
                AppLog.log("[ChatService] Pool offer aborted - could not reserve fresh spending addresses")
                return
            }
            // Pool reservations are born VISIBLE: they appear in Manage Addresses immediately,
            // tagged as chat privacy addresses, so the user can see exactly which addresses are
            // held ready for contacts to pay into. (They used to be born hidden - see
            // WalletManager.unhideOfferedReservationsIfNeeded for the migration of old state.)
            let entries = fresh.map {
                PaymentPoolStore.ReservedAddress(address: $0.address, index: $0.index, offered: false, funded: nil)
            }
            store.recordMyReservations(entries, for: contact.address, wallet: walletAddress)
            pending.append(contentsOf: entries)
        }
        guard !pending.isEmpty else { return }

        let payload = PaymentPoolCodec.encode(
            AddressPoolContent(addresses: pending.map(\.address), replace: replace)
        )
        guard !payload.isEmpty else { return }

        try await sendInvisiblePoolEnvelope(to: contact, payload: payload)

        // replace-ness propagates: a replace batch supersedes any other still-active offer to
        // this contact (those revert to normal rows), an append top-up only activates its own.
        store.markReservationsOffered(pending.map(\.address), for: contact.address, wallet: walletAddress, replace: replace)
        // Actively offered addresses are always visible in Manage Addresses. Fresh indices
        // were never hidden; this covers reservations recorded under the old born-hidden
        // design whose send failed back then and only now succeeded.
        WalletManager.shared.unhideReservedIndices(pending.map(\.index))
        store.markPoolOffered(to: contact.address, wallet: walletAddress)
        store.recordPoolOfferServed(to: contact.address, wallet: walletAddress)
        store.clearPoolRevocation(for: contact.address, wallet: walletAddress)
        AppLog.log("[ChatService] Offered %d fresh pool addresses to %@ (replace=%@)",
                   pending.count, String(contact.address.suffix(10)), replace ? "true" : "false")

        // Rebuilds the full subscription set, which now includes the just-offered addresses.
        await addContactToUtxoSubscription(contact.address)
    }

    // MARK: - Chats Privacy toggle propagation

    /// Called from the Settings toggle after the per-account flag is persisted. Both directions
    /// propagate PROACTIVELY - the toggle is the switch, not conversation-opening:
    ///
    /// - OFF revokes our pool at every contact holding one (empty replace:true - the wire
    ///   revocation primitive) so their very next payment falls back to our chatting address
    ///   instead of draining the residual pool.
    /// - ON clears revocation markers and immediately broadcasts fresh offers to every
    ///   established contact not currently holding a live pool - contacts we revoked, contacts
    ///   whose revoke landed while their app was closed, and established contacts never offered
    ///   before. (The lazy enterConversation offer remains as backstop for conversations that
    ///   become established later.)
    ///
    /// Toggle broadcasts clear the short transition gap (60s per contact) rather than the full
    /// 10-minute serve throttle, so deliberate flips always propagate promptly while rapid
    /// flapping stays bounded to one broadcast per contact per gap.
    func handleChatsPrivacyToggleChanged(enabled: Bool) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        if enabled {
            PaymentPoolStore.shared.clearAllPoolRevocations(wallet: wallet.publicAddress)
            reofferPoolsForChatsPrivacyOn()
        } else {
            revokeOfferedPoolsForChatsPrivacyOff()
        }
    }

    /// Toggle-ON proactive broadcast: one `replace:true` offer per established contact that
    /// doesn't currently hold a live pool of ours (offered marker unset - covers revoked
    /// contacts AND never-offered ones), serialized through the outgoing queue, bounded by the
    /// established-conversation count and the per-contact transition gap + reservation caps.
    /// Contacts skipped by the gap are picked up by the lazy enterConversation offer later.
    func reofferPoolsForChatsPrivacyOn() {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let store = PaymentPoolStore.shared

        let targets = conversations
            .map { $0.contact.address }
            .filter { address in
                isPoolEstablishedConversation(address)
                    && !store.hasOfferedPool(to: address, wallet: walletAddress)
            }
        guard !targets.isEmpty else { return }
        AppLog.log("[ChatService] Chats Privacy on - re-offering pools to %d contacts", targets.count)

        Task { @MainActor [weak self] in
            guard let self else { return }
            for contactAddress in targets {
                // The toggle may flip back OFF mid-broadcast - stop offering.
                guard AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
                guard let contact = self.contactsManager.getContact(byAddress: contactAddress) else { continue }
                do {
                    try await self.enqueueOutgoingTxOperation {
                        try await self.reserveAndSendAddressPool(to: contact, replace: true, toggleTransition: true)
                    }
                } catch {
                    AppLog.log("[ChatService] Toggle-on pool offer to %@ failed (lazy offer remains): %@",
                               String(contactAddress.suffix(10)), error.localizedDescription)
                }
            }
        }
    }

    /// One revoke per contact currently holding our pool (per PERSISTED state - offered marker
    /// unioned with offered-flagged reservations, minus already-revoked), serialized through
    /// the outgoing queue. Failures are logged and non-fatal - the contact then simply drains
    /// the residual pool (the pre-revocation backstop semantics), and the contact stays
    /// eligible for a retry on a later toggle-off. Each successful revoke stamps the serve
    /// timestamp; toggle broadcasts in either direction then honor the 60s per-contact
    /// transition gap, bounding rapid flapping while keeping deliberate flips prompt.
    func revokeOfferedPoolsForChatsPrivacyOff() {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let targets = PaymentPoolStore.shared.contactsHoldingOurPool(wallet: walletAddress)
        guard !targets.isEmpty else { return }
        AppLog.log("[ChatService] Chats Privacy off - revoking offered pools at %d contacts", targets.count)

        Task { @MainActor [weak self] in
            guard let self else { return }
            for contactAddress in targets {
                // The toggle may flip back ON mid-broadcast - stop revoking, the remaining
                // contacts keep their (again welcome) pools.
                guard !AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
                // Flap bound: revokes bypass the reservation caps (a revoke must always be
                // allowed out) but honor the 60s transition gap per contact. A gap-skipped
                // contact keeps its markers, so a later toggle-off retries it; meanwhile the
                // residual-drain backstop applies.
                guard !PaymentPoolStore.shared.isWithinPoolServeGap(for: contactAddress, wallet: walletAddress, toggleTransition: true) else {
                    AppLog.log("[ChatService] Revoke to %@ deferred by transition gap", String(contactAddress.suffix(10)))
                    continue
                }
                guard let contact = self.contactsManager.getContact(byAddress: contactAddress) else { continue }
                let payload = PaymentPoolCodec.encode(AddressPoolContent(addresses: [], replace: true))
                guard !payload.isEmpty else { return }
                do {
                    try await self.enqueueOutgoingTxOperation {
                        // Re-checked once the queue serializes us, same reasoning as offers.
                        guard !AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
                        guard !PaymentPoolStore.shared.isPoolRevoked(for: contactAddress, wallet: walletAddress) else { return }
                        try await self.sendInvisiblePoolEnvelope(to: contact, payload: payload)
                        PaymentPoolStore.shared.markPoolRevoked(for: contactAddress, wallet: walletAddress)
                        PaymentPoolStore.shared.recordPoolOfferServed(to: contactAddress, wallet: walletAddress)
                    }
                    AppLog.log("[ChatService] Revoked pool at %@", String(contactAddress.suffix(10)))
                } catch {
                    AppLog.log("[ChatService] Pool revoke to %@ failed (non-fatal, residual drain applies): %@",
                               String(contactAddress.suffix(10)), error.localizedDescription)
                }
            }
        }
    }

    /// Sends `addr_pool_request` when the stored pool for `contact` has run low (<=
    /// `PaymentPoolStore.lowWaterMark` unused) - throttled per contact so a burst of payments or
    /// conversation opens doesn't spam requests. Called after pool-address consumption and on
    /// conversation open.
    func maybeRequestMorePoolAddresses(from contact: Contact) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        // Chats Privacy OFF: we aren't consuming pool addresses, so never ask for more.
        guard AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
        guard PaymentPoolStore.shared.shouldRequestMoreAddresses(from: contact.address, wallet: walletAddress) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = PaymentPoolCodec.encode(AddressPoolRequestContent())
            guard !payload.isEmpty else { return }
            do {
                try await self.enqueueOutgoingTxOperation {
                    try await self.sendInvisiblePoolEnvelope(to: contact, payload: payload)
                }
                PaymentPoolStore.shared.recordPoolRequestSent(to: contact.address, wallet: walletAddress)
                AppLog.log("[ChatService] Requested fresh pool addresses from %@", String(contact.address.suffix(10)))
            } catch {
                AppLog.log("[ChatService] addr_pool_request send failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Auto-replenish (pool of 2)

    /// Keeps a contact who holds a live pool of ours topped up to `PaymentPoolStore.offerBatchSize`
    /// fresh (unfunded, active) addresses. Fired whenever one of their reservations is detected
    /// USED - a `payment_notice` naming it, or the UTXO watch seeing funds arrive on it - and
    /// re-checked on every conversation open, so a top-up whose send failed earlier gets retried.
    /// Sends an ADDITIVE `addr_pool` (`replace: false`) carrying only the shortfall.
    ///
    /// Caps and throttles: the reservation caps (lifetime, outstanding-unfunded) apply in full,
    /// and the 60s per-contact transition gap bounds rapid re-fires, but the 10-minute serve
    /// throttle is bypassed - this is a replenish driven by genuine pool consumption, not a
    /// re-offer (same exemption pattern as toggle broadcasts/revokes; see MESSAGING.md). The
    /// shortfall is recomputed inside the serialized send operation, so stacked triggers for
    /// the same funding collapse to a single send.
    func replenishPoolIfNeeded(for contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        guard AppSettings.chatsPrivacyEnabled(for: walletAddress) else { return }
        let store = PaymentPoolStore.shared
        // Only contacts currently holding a live pool of ours get proactive top-ups - a
        // never-offered contact goes through the normal initial offer, and a revoked one
        // through the toggle-on re-offer.
        guard store.hasOfferedPool(to: contactAddress, wallet: walletAddress) else { return }
        guard !store.isPoolRevoked(for: contactAddress, wallet: walletAddress) else { return }
        // A contact who revoked our pool at them zeroed their active count deliberately -
        // that's disinterest, not consumption; never replenish until they re-engage.
        guard !store.didContactRevokeAtUs(contactAddress, wallet: walletAddress) else { return }
        guard store.activeFreshReservationCount(for: contactAddress, wallet: walletAddress) < PaymentPoolStore.offerBatchSize else { return }
        guard isPoolEstablishedConversation(contactAddress) else { return }
        guard let contact = contactsManager.getContact(byAddress: contactAddress) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.enqueueOutgoingTxOperation {
                try await self.reserveAndSendAddressPool(to: contact, replace: false, replenish: true)
            }
        }
    }

    /// UTXO-watch side of funded detection: offered reservation addresses are in the gRPC
    /// `utxosChanged` watched set (see `setupUtxoSubscription`), but the chat classifier
    /// deliberately skips them ("unknown address" case) and `AddressActivityNotifier` excludes
    /// them from wallet notifications - so before this hook, nothing marked a reservation
    /// funded unless the payer's `payment_notice` arrived. Called with every notification
    /// batch's added entries: any entry landing on an offered reservation marks it funded
    /// (idempotent - only an actual transition triggers anything), force-unhides its row
    /// (funded addresses are always visible in Manage Addresses), and tops the contact's
    /// pool back up.
    func handlePoolReservationUtxoAdditions(_ added: [ParsedUtxoEntry]) {
        guard !added.isEmpty, let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let store = PaymentPoolStore.shared
        let offered = Set(store.allOfferedReservationAddresses(wallet: walletAddress))
        guard !offered.isEmpty else { return }

        var contactsToReplenish = Set<String>()
        for entry in added {
            guard let address = entry.address, offered.contains(address) else { continue }
            guard let contactAddress = store.reservationContact(for: address, wallet: walletAddress) else { continue }
            if store.markReservationFunded(address, for: contactAddress, wallet: walletAddress) {
                AppLog.log("[ChatService] Pool reservation %@ funded via UTXO watch (contact %@) - replenishing",
                           String(address.suffix(10)), String(contactAddress.suffix(10)))
                // Funded addresses are always visible in the main list.
                if let index = store.reservationIndex(for: address, wallet: walletAddress) {
                    Task { _ = await WalletManager.shared.setSpendingAddressHidden(index: index, hidden: false) }
                }
                contactsToReplenish.insert(contactAddress)
            }
        }
        for contactAddress in contactsToReplenish {
            replenishPoolIfNeeded(for: contactAddress)
        }
    }

    // MARK: - Paying into a contact's pool

    /// Where a 1:1 chat payment is funded FROM under the current Chats Payment Privacy setting:
    /// the primary spending-chain address when ON (the existing behavior), the CHATTING address
    /// when OFF - the toggle's OFF promise is chatting-to-chatting end to end, source included.
    /// Must be used by every estimator that predicts what `sendPaymentInternal` will spend, or
    /// the estimate silently computes against the wrong balance/UTXO set.
    func paymentFundingSourceAddress() throws -> String {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        if !AppSettings.chatsPrivacyEnabled(for: wallet.publicAddress) {
            return wallet.publicAddress
        }
        guard let spendingAddress = WalletManager.shared.currentSpendingAddress() else {
            throw KasiaError.walletNotFound
        }
        return spendingAddress
    }

    /// The destination address for a payment to `contact`: an unused address from their stored
    /// pool if one exists (consumed immediately - persisted, never offered to another payment
    /// even if this one fails), else the chatting address (exact pre-pool behavior). A retry of
    /// the same payment (same `pendingTxId`) reuses the address already consumed for it instead
    /// of burning another.
    ///
    /// CROSS-DEVICE DOUBLE-PAY PROTECTION: the pool's `used` flags are device-local, so when
    /// the same seed runs on two devices, a payment sent from device A never marks the address
    /// used on device B - B's next payment would land on the very address the pool feature
    /// exists to keep fresh. Before consuming a candidate, this probes its on-chain history
    /// (uncached transactions-count fetch, see `addressHasOnChainHistory`); an address with
    /// ANY history is marked used locally (the skip persists) and the walk moves to the next
    /// unused one. Only a genuinely failed probe (network error, unknown) consumes the
    /// candidate anyway - a rare reuse beats failing the payment or silently leaking it to
    /// the chatting address. The walk is bounded by the stored pool itself (at most
    /// `PaymentPoolStore.maxStoredPoolSize` entries, typically `offerBatchSize`); every probe
    /// is a one-integer body with an 8s timeout, and the first failure ends the probing.
    /// If every pool address turns out used, the payment falls back to the chatting address
    /// and the existing low-water `addr_pool_request` path asks the contact for more.
    ///
    /// async because of the probes; callers already run inside the serialized outgoing-tx
    /// queue (`enqueueOutgoingTxOperation`), so the awaits cannot race another payment onto
    /// the same pool slot.
    ///
    /// Deliberately NOT gated on the sender's Chats Payment Privacy toggle: the RECIPIENT'S
    /// privacy governs the destination - if they shared fresh addresses, money arrives on one
    /// no matter the sender's setting. The sender's toggle only governs the FUNDING side
    /// (see `paymentFundingSourceAddress`).
    func poolPaymentDestination(for contact: Contact, pendingTxId: String) async -> String {
        let store = PaymentPoolStore.shared
        if let remembered = store.paymentDestination(forPendingTxId: pendingTxId) {
            return remembered
        }
        guard let wallet = WalletManager.shared.currentWallet else { return contact.address }
        let walletAddress = wallet.publicAddress

        // Addresses another device already paid, discovered by the probes below. If any were
        // skipped, the pool may have silently run low - run the (throttled, low-water-gated)
        // top-up request on the way out, since the normal post-send request in
        // `handlePoolPaymentSubmitted` never fires for a chatting-address fallback.
        var skippedUsedElsewhere = 0
        defer {
            if skippedUsedElsewhere > 0 {
                maybeRequestMorePoolAddresses(from: contact)
            }
        }

        // Each iteration either consumes the head unused address (returns) or marks it used
        // (persisted) and re-reads, so the loop is bounded by the stored pool size.
        while let poolAddress = store.nextUnusedPoolAddress(for: contact.address, wallet: walletAddress) {
            guard KaspaAddress.publicKey(from: poolAddress) != nil else {
                // Undecodable pool entry: same chatting-address fallback as before.
                return contact.address
            }
            if await addressHasOnChainHistory(poolAddress) == true {
                // Another device (or a straggler payment) already used this address - burn it
                // locally so no future send here picks it either, and walk on.
                store.markPoolAddressUsed(poolAddress, for: contact.address, wallet: walletAddress)
                skippedUsedElsewhere += 1
                AppLog.log("[ChatService] Pool address %@ for %@ already has chain history (used by another device?) - skipping",
                           String(poolAddress.suffix(10)), String(contact.address.suffix(10)))
                continue
            }
            // Probe said clean (false) or could not answer (nil - proceed as today rather
            // than fail the payment): consume this address.
            store.markPoolAddressUsed(poolAddress, for: contact.address, wallet: walletAddress)
            store.rememberPaymentDestination(poolAddress, pendingTxId: pendingTxId)
            AppLog.log("[ChatService] Payment to %@ will use fresh pool address %@",
                       String(contact.address.suffix(10)), String(poolAddress.suffix(10)))
            return poolAddress
        }
        return contact.address
    }

    /// True when the NEXT payment to this contact would go to a fresh pool address - drives the
    /// subtle "fresh address" indicator in the payment composer and the tip sheet. Matches
    /// `poolPaymentDestination`: recipient-governed, independent of the sender's privacy toggle.
    func willPayViaFreshPoolAddress(contactAddress: String) -> Bool {
        guard let wallet = WalletManager.shared.currentWallet else { return false }
        return PaymentPoolStore.shared.nextUnusedPoolAddress(for: contactAddress, wallet: wallet.publicAddress) != nil
    }

    /// Called by `sendPaymentInternal` after a pool-address payment tx is accepted: sends the
    /// `payment_notice` envelope (fire-and-forget, chained behind the current tx operation) so
    /// the recipient's chat shows the payment bubble their chain-side detection would miss, then
    /// checks the low-water mark. No-op for chatting-address payments - existing detection
    /// already covers those.
    func handlePoolPaymentSubmitted(
        contact: Contact,
        txId: String,
        amountSompi: UInt64,
        destinationAddress: String,
        pendingTxId: String
    ) {
        PaymentPoolStore.shared.forgetPaymentDestination(pendingTxId: pendingTxId)
        guard destinationAddress != contact.address else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let payload = PaymentPoolCodec.encode(
                PaymentNoticeContent(txId: txId, amountSompi: amountSompi, address: destinationAddress)
            )
            guard !payload.isEmpty else { return }
            do {
                try await self.enqueueOutgoingTxOperation {
                    try await self.sendInvisiblePoolEnvelope(to: contact, payload: payload)
                }
                AppLog.log("[ChatService] Sent payment_notice for %@", String(txId.prefix(12)))
            } catch {
                // The payment itself succeeded; a lost notice only means the recipient's bubble
                // waits for their own address discovery / manual sync. Not retried automatically.
                AppLog.log("[ChatService] payment_notice send failed for %@: %@",
                           String(txId.prefix(12)), error.localizedDescription)
            }
            self.maybeRequestMorePoolAddresses(from: contact)
        }
    }

    // MARK: - Receiving envelopes

    /// Front door for all three pool envelope types, called from `addMessageToConversation`'s
    /// interception - these never become bubbles (except the payment bubble a `payment_notice`
    /// deliberately creates). Replay-guarded by envelope txId: history re-fetch replays the same
    /// envelopes and must not re-trigger reservation sends or pool merges.
    func handlePaymentPoolEnvelope(_ envelope: PaymentPoolEnvelope, message: ChatMessage, contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let store = PaymentPoolStore.shared

        // Pending (not-yet-submitted) local sends have synthetic ids; only real txIds are
        // meaningful for the replay guard.
        let hasRealTxId = !message.txId.hasPrefix("pending_")
        if hasRealTxId {
            guard !store.isEnvelopeHandled(txId: message.txId, wallet: walletAddress) else { return }
            store.markEnvelopeHandled(txId: message.txId, wallet: walletAddress)
        }

        switch envelope {
        case .pool(let content):
            // Deliberately NOT gated by Chats Privacy: an incoming pool is harmless to store
            // and ready the moment the user re-enables the toggle. (The reciprocity offer it
            // may trigger IS gated, inside offerAddressPoolIfNeeded.)
            //
            // Our own outgoing addr_pool re-fetched from the indexer: nothing to do (send-time
            // bookkeeping already happened; after a device restore the offered marker is empty
            // again and the lazy offer re-runs with replace:true, which is the designed recovery).
            guard !message.isOutgoing else { return }
            guard isPoolEstablishedConversation(contactAddress) else {
                AppLog.log("[ChatService] Ignoring addr_pool from non-established conversation %@",
                           String(contactAddress.suffix(10)))
                return
            }
            acceptIncomingAddressPool(content, from: contactAddress, wallet: walletAddress)

        case .request:
            guard !message.isOutgoing else { return }
            // Chats Privacy OFF: silently ignore (same no-error semantics as the rate limits) -
            // the requester's payments fall back to our chatting address once their stored pool
            // of our addresses runs out.
            guard AppSettings.chatsPrivacyEnabled(for: walletAddress) else {
                AppLog.log("[ChatService] Ignoring addr_pool_request from %@ - Chats Privacy off",
                           String(contactAddress.suffix(10)))
                return
            }
            guard isPoolEstablishedConversation(contactAddress) else { return }
            // An explicit request is renewed interest - a standing revoked-at-us marker (they
            // once revoked our pool) no longer applies, so auto-replenish resumes for them.
            store.clearContactRevokedAtUs(contactAddress, wallet: walletAddress)
            // Inbound abuse gate: every reply costs us a reservation batch AND an on-chain tx
            // fee, so a contact spamming addr_pool_request gets at most one top-up per
            // 10 minutes, and nothing once the lifetime/outstanding-unfunded caps are hit
            // (re-checked inside reserveAndSendAddressPool once the queue serializes us).
            guard store.canServePoolOffer(to: contactAddress, wallet: walletAddress) else {
                AppLog.log("[ChatService] Ignoring addr_pool_request from %@ - serve throttle/caps",
                           String(contactAddress.suffix(10)))
                return
            }
            guard let contact = contactsManager.getContact(byAddress: contactAddress) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.enqueueOutgoingTxOperation {
                    // Top-up batch: append semantics, the recipient dedupes.
                    try await self.reserveAndSendAddressPool(to: contact, replace: false)
                }
            }

        case .notice(let content):
            // Deliberately NOT gated by Chats Privacy: previously offered addresses remain
            // valid (and watched) whatever the toggle says now, so payments to them must keep
            // rendering.
            //
            // The payer's own notice re-fetched: swallow - the payer's bubble was created by
            // `sendPaymentInternal` at send time.
            guard !message.isOutgoing else { return }
            createPaymentBubbleFromNotice(content, from: contactAddress, noticeBlockTime: message.blockTime)
        }
    }

    /// Validates and stores a received `addr_pool` as "addresses I can pay this contact at".
    /// Per-address validation: bech32-valid, correct network prefix, not our chatting address,
    /// not an address we ourselves reserved, not one of our own spending-chain addresses. The
    /// accepted list is capped at `PaymentPoolStore.maxStoredPoolSize`.
    private func acceptIncomingAddressPool(_ content: AddressPoolContent, from contactAddress: String, wallet walletAddress: String) {
        let store = PaymentPoolStore.shared
        let expectedPrefix = currentSettings.networkType == .mainnet ? "kaspa:" : "kaspatest:"

        var accepted: [String] = []
        for raw in content.addresses.prefix(PaymentPoolStore.maxStoredPoolSize) {
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard address.hasPrefix(expectedPrefix),
                  KaspaAddress.isValid(address),
                  address != walletAddress,
                  !store.isReservedAddress(address, wallet: walletAddress),
                  !WalletManager.shared.isOwnSpendingAddress(address) else {
                AppLog.log("[ChatService] Rejected pool address from %@: %@",
                           String(contactAddress.suffix(10)), String(address.suffix(14)))
                continue
            }
            accepted.append(address)
        }

        // REVOCATION PRIMITIVE (must be honored - see MESSAGING.md): a replace:true pool that
        // is empty after validation clears this contact's stored pool entirely. The contact
        // turned off Chats Privacy (or is retracting an offer) - our next payment to them falls
        // back to their chatting address, and `willPayViaFreshPoolAddress` goes false the
        // moment the empty pool is stored. No reciprocity on a revoke.
        if content.replace == true && accepted.isEmpty {
            store.mergeTheirPool(addresses: [], replace: true, for: contactAddress, wallet: walletAddress)
            // The contact signalled pool disinterest (Chats Privacy off on their side): our
            // offers to them leave the ACTIVE set too - their Manage Addresses rows revert to
            // normal, untagged, hideable addresses. Protocol state (offered marker, watch set,
            // payment_notice rendering) is untouched: a payment racing this revoke, or a
            // straggler send into the old pool, still lands and renders.
            store.markOffersInactive(for: contactAddress, wallet: walletAddress)
            AppLog.log("[ChatService] Pool REVOKED by %@ - cleared stored pool", String(contactAddress.suffix(10)))
            return
        }
        guard !accepted.isEmpty else { return }

        store.mergeTheirPool(
            addresses: accepted,
            replace: content.replace == true,
            for: contactAddress,
            wallet: walletAddress
        )
        // A non-empty pool offer means the contact participates in the feature again - any
        // standing revoked-at-us marker (from an earlier revoke of theirs) is stale.
        store.clearContactRevokedAtUs(contactAddress, wallet: walletAddress)
        AppLog.log("[ChatService] Stored %d pool addresses for %@ (replace=%@)",
                   accepted.count, String(contactAddress.suffix(10)),
                   content.replace == true ? "true" : "false")

        // Reciprocity: they shared theirs - if they've never gotten ours, offer now.
        if !store.hasOfferedPool(to: contactAddress, wallet: walletAddress) {
            offerAddressPoolIfNeeded(to: contactAddress)
        }
    }

    /// Renders a received `payment_notice` as a normal incoming payment bubble, deduped by the
    /// payment's txId. Rendering is NOT blocked on chain verification - the notice arrived over
    /// the sender-authenticated encrypted channel - but a background check against the REST API
    /// corrects the amount from chain data and flags the bubble `.warning` if the referenced tx
    /// has no output to the claimed address.
    private func createPaymentBubbleFromNotice(_ content: PaymentNoticeContent, from contactAddress: String, noticeBlockTime: UInt64) {
        let txId = content.txId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !txId.isEmpty, content.amountSompi > 0 else { return }

        // The notice names the reserved address the contact paid - record it funded so the
        // outstanding-unfunded-offers cap reflects genuine pool usage (no-op if the address
        // isn't one of our reservations for this contact). An actual funded transition also
        // triggers the pool-of-2 auto-replenish so the contact is topped back up to
        // `offerBatchSize` fresh addresses.
        if let wallet = WalletManager.shared.currentWallet {
            let transitioned = PaymentPoolStore.shared.markReservationFunded(content.address, for: contactAddress, wallet: wallet.publicAddress)
            // The reserved address now holds money — funded addresses are always visible.
            // Reservations are born visible now, so this is normally a no-op; it still
            // repairs any legacy reservation left hidden by the old born-hidden design.
            if let index = PaymentPoolStore.shared.reservationIndex(for: content.address, wallet: wallet.publicAddress) {
                Task { _ = await WalletManager.shared.setSpendingAddressHidden(index: index, hidden: false) }
            }
            if transitioned {
                replenishPoolIfNeeded(for: contactAddress)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.findLocalMessage(txId: txId) == nil else { return }

            let template = AppLocalization.string("Received %@ KAS")
            let bubble = ChatMessage(
                txId: txId,
                senderAddress: contactAddress,
                receiverAddress: content.address,
                content: String(format: template, self.formatKasAmount(content.amountSompi)),
                timestamp: Date(timeIntervalSince1970: TimeInterval(noticeBlockTime / 1000)),
                blockTime: noticeBlockTime,
                acceptingBlock: nil,
                isOutgoing: false,
                messageType: .payment,
                deliveryStatus: .sent
            )
            self.addMessageToConversation(bubble, contactAddress: contactAddress)
            self.saveMessages()
            AppLog.log("[ChatService] Created payment bubble from payment_notice %@", String(txId.prefix(12)))

            await self.verifyPaymentNoticeAgainstChain(
                txId: txId,
                claimedAddress: content.address,
                claimedAmount: content.amountSompi
            )
        }
    }

    /// Best-effort background verification of a `payment_notice` against the on-chain tx. Silent
    /// on network failure (verification is opportunistic by design); corrects the bubble's amount
    /// if the chain disagrees; marks the bubble `.warning` if the tx exists but pays nothing to
    /// the claimed address.
    private func verifyPaymentNoticeAgainstChain(
        txId: String,
        claimedAddress: String,
        claimedAmount: UInt64
    ) async {
        guard let url = kaspaRestURL(path: "/transactions/\(txId)") else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) else {
            return
        }
        let paidToClaimed = fullTx.outputs
            .filter { $0.scriptPublicKeyAddress == claimedAddress }
            .reduce(UInt64(0)) { $0 + $1.amount }

        if paidToClaimed == 0 {
            AppLog.log("[ChatService] payment_notice %@ FAILED verification - no output to claimed address", String(txId.prefix(12)))
            let template = AppLocalization.string("Received %@ KAS")
            _ = updateIncomingPaymentStatus(
                txId: txId,
                deliveryStatus: .warning,
                content: String(format: template, formatKasAmount(claimedAmount))
            )
            saveMessages()
        } else if paidToClaimed != claimedAmount {
            // Chain is authoritative for the amount.
            let template = AppLocalization.string("Received %@ KAS")
            _ = updateIncomingPaymentStatus(
                txId: txId,
                deliveryStatus: .sent,
                content: String(format: template, formatKasAmount(paidToClaimed))
            )
            saveMessages()
        }
    }

    // MARK: - Shared plumbing

    /// A conversation counts as established for pool purposes once both directions have spoken
    /// (at least one incoming AND one outgoing message) - the same bar for offering our pool and
    /// for accepting a contact's.
    func isPoolEstablishedConversation(_ contactAddress: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.contact.address == contactAddress }) else {
            return false
        }
        let hasIncoming = conversation.messages.contains { !$0.isOutgoing }
        let hasOutgoing = conversation.messages.contains { $0.isOutgoing }
        return hasIncoming && hasOutgoing
    }

    /// Sends an invisible pool envelope through the normal encrypted contextual-message pipeline.
    /// Mirrors `sendReactionInternal`'s tx construction exactly (self-stash contextual message to
    /// the contact's chatting address), minus any bubble/pending bookkeeping - these envelopes
    /// must never surface in the conversation. Callers wrap this in `enqueueOutgoingTxOperation`.
    func sendInvisiblePoolEnvelope(to contact: Contact, payload: String) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)

        let rpcManager = NodePoolService.shared
        if !rpcManager.isConnected {
            try await rpcManager.connect(network: currentSettings.networkType)
        }

        let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
        let candidateUtxos = prepareMessageUtxos(confirmed: utxos)
        guard !candidateUtxos.isEmpty else {
            throw KasiaError.networkError(noSpendableFundsYetMessage())
        }

        let transaction = try KasiaTransactionBuilder.buildContextualMessageTx(
            from: wallet.publicAddress,
            to: contact.address,
            alias: alias,
            message: payload,
            senderPrivateKey: privateKey,
            recipientPublicKey: recipientPublicKey,
            utxos: candidateUtxos,
            feeOverride: nil
        )
        let spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }
        let submitted = try await rpcManager.submitTransaction(transaction, allowOrphan: usesUnconfirmedInputs)

        reserveMessageOutpoints(spentUtxos)
        consumePendingUtxos(spentUtxos)
        addPendingOutputs(from: transaction, txId: submitted.txId, senderScriptPubKey: senderScriptPubKey)

        // Remember our own envelope's txId so the eventual indexer re-fetch of this outgoing
        // message is dropped by the replay guard without re-entering the handler logic.
        PaymentPoolStore.shared.markEnvelopeHandled(txId: submitted.txId, wallet: wallet.publicAddress)
    }
}
