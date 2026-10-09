import Foundation
import UIKit

@MainActor
final class ContactsManager: ObservableObject {
    static let shared = ContactsManager()

    @Published var contacts: [Contact] = [] {
        didSet { rebuildAddressIndex() }
    }

    /// Address -> contact, rebuilt whenever `contacts` changes.
    ///
    /// `getContact(byAddress:)` used to be a linear scan of `contacts`, and it is called from 27
    /// view bodies - three times per avatar per render pass - and once per ingested message. With
    /// a few hundred contacts that was tens of thousands of string compares on every publish
    /// burst, multiplying the cost of everything that renders a person. Contacts change rarely
    /// and are looked up constantly, so the index is rebuilt on write and free on read. Keeps the
    /// first occurrence of an address, matching what `first(where:)` returned.
    private var contactsByAddress: [String: Contact] = [:]

    private func rebuildAddressIndex() {
        var index: [String: Contact] = [:]
        index.reserveCapacity(contacts.count)
        for contact in contacts where index[contact.address] == nil {
            index[contact.address] = contact
        }
        contactsByAddress = index
    }
    @Published var isLoading = false
    @Published var error: KasiaError?
    @Published var isFetchingKNS = false
    @Published private(set) var contactBalances: [String: UInt64] = [:]

    private let userDefaults = UserDefaults.standard
    private let legacyContactsKey = "kachat_contacts"
    private let contactsKeyPrefix = "kachat_contacts_wallet_"
    private let deletedAddressesKeyPrefix = "kachat_deleted_contacts_wallet_"
    private let deletedTxIdsKeyPrefix = "kachat_deleted_contact_txids_wallet_"
    private let deletedAtKeyPrefix = "kachat_deleted_contacts_at_wallet_"
    /// Addresses of permanently-deleted contacts for the active wallet, kept even after the
    /// `Contact` itself is gone - matches Android's `DeletedContactEntity` tombstone, so an
    /// incoming message or handshake from a deleted address never silently recreates the contact.
    private var deletedAddresses: Set<String> = []
    /// Address -> the txIds mined at exactly `deletedAtByAddress[address]`.
    ///
    /// Kaspa's per-sender block_time is not strictly monotonic, so two different transactions can
    /// share the deletion instant: the last one we had before deleting, and a genuinely new
    /// handshake that happens to land in the same millisecond. `blockTime <= deletedAt` alone
    /// cannot tell them apart and drops the new one. These are the ids that were already ours at
    /// that instant, so anything else sharing it is new. Android has always carried this
    /// (DeletedContactEntity.deletedAtTxIds); iOS was the one comparing on time alone.
    private var deletedTxIdsByAddress: [String: Set<String>] = [:]

    /// Address -> when it was tombstoned (ms). See `isDeletedAsOf(_:txId:blockTime:)`.
    private var deletedAtByAddress: [String: Int64] = [:]
    private var activeWalletAddress: String?
    private var lastMessageSaveWorkItem: DispatchWorkItem?
    private let lastMessageSaveDelay: TimeInterval = 0.6
    private var sharedSyncWorkItem: DispatchWorkItem?
    private var pushUpdateWorkItem: DispatchWorkItem?
    private let sharedSyncDelay: TimeInterval = 0.8
    private let pushUpdateDelay: TimeInterval = 0.8
    private var lastSharedSyncAt: Date?
    private var lastPushUpdateAt: Date?
    private let minSharedSyncInterval: TimeInterval = 5.0
    private let minPushUpdateInterval: TimeInterval = 5.0
    private let knsService = KNSService.shared
    private var balanceFetchInFlight: Set<String> = []
    private var balanceLastFetch: [String: Date] = [:]
    private let balanceMinInterval: TimeInterval = 30.0

    private init() {
        contacts = []
        Task.detached(priority: .utility) { CacheManager.removeRetiredContactPhotos() }
    }

    var activeContacts: [Contact] {
        contacts
    }

    /// True when `address` is tombstoned at all - use this only for "should this address appear
    /// in a list", never to decide whether incoming on-chain activity may land. For that, use
    /// `isDeletedAsOf(_:blockTime:)`, which lets genuinely NEW activity through.
    func isAddressDeleted(_ address: String) -> Bool {
        deletedAddresses.contains(address)
    }

    /// Drops the tombstone entirely - the conversation is live again.
    ///
    /// Called when a handshake that post-dates the deletion is accepted: the other side has
    /// re-initiated contact and we let it through, so every later message from them must land
    /// normally rather than hitting the tombstone again.
    func clearDeletionTombstone(_ address: String) {
        guard deletedAddresses.remove(address) != nil else { return }
        deletedAtByAddress.removeValue(forKey: address)
        deletedTxIdsByAddress.removeValue(forKey: address)
        saveDeletedAddresses()
    }

    /// When `address` was deleted, in the indexer's block-time clock (ms), or nil if never.
    func deletedAt(_ address: String) -> Int64? {
        deletedAtByAddress[address]
    }

    /// Whether activity mined at `blockTime` should be suppressed for `address`.
    ///
    /// A tombstone exists to stop a DELETED conversation silently coming back when the indexer
    /// re-serves its history - not to blacklist the person. A handshake or message sent AFTER the
    /// deletion is a new request, and blocking it meant deleting a chat quietly made you
    /// unreachable to that person forever, with nothing on either end to show why. Matches
    /// Android's `isTombstoned`, which has always compared against `deletedAt`.
    ///
    /// `blockTime` of 0/nil means "no time in hand" and is treated as pre-deletion, i.e. still
    /// suppressed - the conservative choice, since that is the re-serve case.
    func isDeletedAsOf(_ address: String, txId: String?, blockTime: Int64?) -> Bool {
        guard deletedAddresses.contains(address) else { return false }
        guard let blockTime, blockTime > 0, let deletedAt = deletedAtByAddress[address] else { return true }
        if blockTime < deletedAt { return true }
        // Same instant as the deletion: suppress only what was already ours then. See
        // `deletedTxIdsByAddress` for why time alone is not enough.
        if blockTime == deletedAt {
            guard let txId, !txId.isEmpty else { return true }
            return deletedTxIdsByAddress[address]?.contains(txId) ?? true
        }
        return false
    }

    /// Snapshot of every deletion tombstone, carried in chat-history backups so a restore on
    /// any device (fresh install included) skips chats the user deleted.
    var deletedAddressSnapshot: [String] {
        Array(deletedAddresses)
    }

    // MARK: - KNS Integration

    /// When the last full sweep finished, so repeat callers do not re-run it.
    private var lastFullKNSSweepAt: Date?
    /// How long a completed sweep stands for. Shorter than KNSService's own 10-minute per-address
    /// debounce, so a sweep inside this window still costs nothing, but this stops the WALK
    /// itself - hundreds of addresses each checked and re-published - from happening at all.
    private static let fullKNSSweepInterval: TimeInterval = 5 * 60

    /// Fetch KNS domains for all contacts.
    ///
    /// Guarded twice, because this walks EVERY contact through two KNS passes and is called from
    /// screens that open often - the chat list, and both KaPosts composers.
    ///
    /// `isFetchingKNS` was being set and never read, so two callers (opening the composer while
    /// the chat list had one running, or the two composer views together) each started their own
    /// full sweep over the same addresses. And nothing remembered a sweep had just finished, so
    /// every composer open started another walk: with a large contact list that is hundreds of
    /// requests, and hundreds of profile-cache publishes into an `@ObservedObject` the composer
    /// is watching, which is a re-render of the editor per landing profile. Reported as the app
    /// freezing on opening the KaPosts composer, with a burst of KNS profile calls before it.
    ///
    /// `force` is for the pull-to-refresh paths, where the user has explicitly asked.
    func fetchKNSDomainsForAllContacts(network: NetworkType = .mainnet, force: Bool = false) async {
        // Every result of this sweep is a .kas name to show for a contact, which 5.2 stopped
        // doing (`KNSService.showsDomainNamesAsIdentity`), so it no longer asks KNS at all.
        guard KNSService.showsDomainNamesAsIdentity else { return }
        guard !contacts.isEmpty else { return }
        guard !isFetchingKNS else { return }
        if !force, let last = lastFullKNSSweepAt,
           Date().timeIntervalSince(last) < Self.fullKNSSweepInterval {
            return
        }

        isFetchingKNS = true
        defer {
            isFetchingKNS = false
            lastFullKNSSweepAt = Date()
        }

        let addresses = contacts.map { $0.address }
        await knsService.refreshIfNeeded(for: addresses, network: network)
        await knsService.refreshProfilesIfNeeded(for: addresses, network: network)

        // Keeps an existing domain-based name fresh. Nothing here NAMES a contact - an
        // unnamed one stays unnamed and resolves through `displayName(for:)` instead.
        for contact in contacts {
            if let knsInfo = knsService.domainCache[contact.address],
               let primaryDomain = knsInfo.primaryDomain {
                // An unnamed contact is deliberately left unnamed: `displayName(for:)` shows
                // their KNS domain, so baking it into the alias would only freeze a name the
                // user never chose - and leave it stale once the domain moves.
                if contact.assignedName == nil {
                    continue
                }
                if contact.alias.lowercased().hasSuffix(".kas") && contact.alias != primaryDomain {
                    // Keep KNS domain fresh when alias is domain-based
                    var updatedContact = contact
                    updatedContact.alias = primaryDomain
                    updateContact(updatedContact)
                }
            }
        }
    }

    /// Get KNS info for a contact
    func getKNSInfo(for contact: Contact) -> KNSAddressInfo? {
        knsService.identityInfo(for: contact.address)
    }

    /// Get KNS domains for a contact
    func getKNSDomains(for contact: Contact) -> [KNSDomain] {
        knsService.identityInfo(for: contact.address)?.allDomains ?? []
    }

    /// Get selected KNS profile for a contact address (primary domain if available).
    func getKNSProfile(for contact: Contact) -> KNSAddressProfileInfo? {
        knsService.profileCache[contact.address]
    }

    /// Fetch KNS info for a specific contact
    func fetchKNSInfo(for contact: Contact, network: NetworkType = .mainnet) async -> KNSAddressInfo? {
        guard KNSService.showsDomainNamesAsIdentity else { return nil }
        return await knsService.fetchInfo(for: contact.address, network: network)
    }

    /// Fetch selected KNS profile for a specific contact.
    func fetchKNSProfile(for contact: Contact, network: NetworkType = .mainnet) async -> KNSAddressProfileInfo? {
        await knsService.fetchProfile(for: contact.address, network: network)
    }

    func balanceSompi(for address: String) -> UInt64? {
        contactBalances[address]
    }

    func refreshBalance(for address: String, force: Bool = false) async {
        if !force, let last = balanceLastFetch[address], Date().timeIntervalSince(last) < balanceMinInterval {
            return
        }
        guard !balanceFetchInFlight.contains(address) else { return }
        balanceFetchInFlight.insert(address)
        defer { balanceFetchInFlight.remove(address) }

        do {
            let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
            let total = utxos.reduce(0) { $0 + $1.amount }
            contactBalances[address] = total
            balanceLastFetch[address] = Date()
            WalletManager.shared.updateBalanceIfCurrentWallet(address: address, utxos: utxos)
        } catch {
            // Ignore balance fetch failures
        }
    }

    // MARK: - Public Methods

    func setActiveWalletAddress(_ walletAddress: String?) {
        let normalizedAddress = normalizeWalletAddress(walletAddress)
        guard activeWalletAddress != normalizedAddress else {
            return
        }

        cancelPendingSaves()
        activeWalletAddress = normalizedAddress
        contactBalances = [:]
        balanceLastFetch = [:]
        balanceFetchInFlight = []
        loadContacts()
        // Right after the contacts load: its one-time migration reads their old phone-contact names.
        AddressBookManager.shared.setActiveWalletAddress(normalizedAddress)
        loadDeletedAddresses()

        if normalizedAddress == nil {
            SharedDataManager.syncContactsForExtension()
        }
    }

    func clearInMemoryContacts(syncShared: Bool = true, updatePush: Bool = false) {
        cancelPendingSaves()
        contacts = []
        contactBalances = [:]
        balanceLastFetch = [:]
        balanceFetchInFlight = []
        if syncShared {
            SharedDataManager.syncContactsForExtension()
        }
        if updatePush {
            Task {
                await PushNotificationManager.shared.updateWatchedAddresses()
            }
        }
    }

    func deletePersistedContacts(forWalletAddress walletAddress: String) {
        guard let normalizedAddress = normalizeWalletAddress(walletAddress) else { return }
        let key = contactsKey(forNormalizedWalletAddress: normalizedAddress)
        userDefaults.removeObject(forKey: key)
        userDefaults.removeObject(forKey: deletedAddressesKey(forNormalizedWalletAddress: normalizedAddress))

        if activeWalletAddress == normalizedAddress {
            clearInMemoryContacts(syncShared: true, updatePush: false)
            deletedAddresses = []
        }
    }

    func loadContacts() {
        guard let contactsKey = activeContactsKey else {
            contacts = []
            return
        }

        if let scopedData = userDefaults.data(forKey: contactsKey),
           let decodedContacts = try? JSONDecoder().decode([Contact].self, from: scopedData) {
            let migrated = migrateLegacyDefaultAliases(decodedContacts, contactsKey: contactsKey)
            // Contacts of the other network (created for mainnet senders whose pushes reached
            // this account after a switch to testnet) are not this account's - drop them.
            let onNetwork = migrated.filter { NetworkType.isOnActiveNetwork($0.address) }
            if onNetwork.count < migrated.count, let data = try? JSONEncoder().encode(onNetwork) {
                userDefaults.set(data, forKey: contactsKey)
                AppLog.log("[ContactsManager] Removed %d contacts that belong to the other network",
                      migrated.count - onNetwork.count)
            }
            contacts = sortContacts(clearKasDomainAliasesOnce(onNetwork, contactsKey: contactsKey))
            return
        }

        // One-time migration from the legacy single-account key to the active wallet-scoped key.
        //
        // ONLY when no wallet-scoped key exists yet. The legacy blob predates per-wallet scoping,
        // so it belongs to whichever account was in use before the upgrade - and nothing in the
        // blob says which one that was. Handing it to "whichever account happens to load first"
        // is a coin flip, and on a device with more than one account it is a cross-account leak:
        // load an empty account first and it absorbs the other account's contacts, which is
        // exactly the symptom reported after a rebuild.
        //
        // With exactly one account on the device, that account IS the owner and the migration is
        // safe. With more than one it is unassignable, so the blob is left alone - untouched
        // rather than given to the wrong account.
        //
        // The test is the ACCOUNT COUNT, not "has any wallet written contacts yet". The latter
        // reads the same most of the time and is wrong in one case that matters: a second account
        // that saves an empty list writes a scoped key of its own, which would then block the
        // first account from ever collecting the contacts that are genuinely its.
        guard WalletManager.shared.savedAccounts.count <= 1 else {
            contacts = []
            return
        }
        if let legacyData = userDefaults.data(forKey: legacyContactsKey),
           let decodedLegacy = try? JSONDecoder().decode([Contact].self, from: legacyData) {
            let migrated = migrateLegacyDefaultAliases(decodedLegacy, contactsKey: nil)
            contacts = sortContacts(migrated)
            if let migratedData = try? JSONEncoder().encode(migrated) {
                userDefaults.set(migratedData, forKey: contactsKey)
                userDefaults.removeObject(forKey: legacyContactsKey)
            }
            return
        }

        contacts = []
    }

    /// One-time upgrade for contacts created before the default-alias format changed from a raw
    /// last-8-characters fallback (e.g. "a1b2c3d4") to Android's "kaspa:xxxx....xxxx" style —
    /// only touches aliases that still exactly match the OLD auto-generated value, leaving
    /// anything the user typed or a resolved KNS domain set alone. Persists the rewrite back to
    /// `contactsKey` (when given) so this only actually runs once per device.
    private func migrateLegacyDefaultAliases(_ input: [Contact], contactsKey: String?) -> [Contact] {
        var didMigrate = false
        let migrated = input.map { contact -> Contact in
            guard contact.address.count > 8, contact.alias == String(contact.address.suffix(8)) else {
                return contact
            }
            var updated = contact
            updated.alias = Contact.generateDefaultAlias(from: contact.address)
            didMigrate = true
            return updated
        }
        if didMigrate, let contactsKey, let data = try? JSONEncoder().encode(migrated) {
            userDefaults.set(data, forKey: contactsKey)
        }
        return migrated
    }

    /// 5.2, once per account: a contact whose name is just a .kas domain - which is how every
    /// automatically named contact got its name before - goes back to unnamed, so it shows as
    /// its address like everyone without a .kachat name (`KNSService.showsDomainNamesAsIdentity`).
    /// A name linked from the Contacts app is left alone. Flagged per account rather than
    /// re-checked every launch, so a .kas-looking name typed after the update stays.
    private func clearKasDomainAliasesOnce(_ input: [Contact], contactsKey: String) -> [Contact] {
        guard !KNSService.showsDomainNamesAsIdentity else { return input }
        let flagKey = "kachat_kas_alias_reset_v1.\(contactsKey)"
        guard !userDefaults.bool(forKey: flagKey) else { return input }
        var didClear = false
        let cleared = input.map { contact -> Contact in
            let alias = contact.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard alias.count > 4, alias.hasSuffix(".kas"),
                  !alias.contains(where: \.isWhitespace) else {
                return contact
            }
            var updated = contact
            updated.alias = Contact.generateDefaultAlias(from: contact.address)
            didClear = true
            return updated
        }
        if didClear, let data = try? JSONEncoder().encode(cleared) {
            userDefaults.set(data, forKey: contactsKey)
            // The notification extension names senders from its own copy - refresh it too.
            scheduleSharedSync()
        }
        userDefaults.set(true, forKey: flagKey)
        return cleared
    }

    func addContact(address: String, alias: String = "", isAutoAdded: Bool = false) throws -> Contact {
        // Validate address format
        guard isValidKaspaAddress(address) else {
            throw KasiaError.invalidAddress
        }
        // A deliberate add is of the network the app runs on: a chat with the other network's
        // address is never read and is dropped on the next launch (IOS-063).
        guard isAutoAdded || KaspaAddress.isValidOnActiveNetwork(address) else {
            throw KasiaError.invalidAddress
        }

        // Never the account itself - there is no one to talk to. Another of the user's OWN
        // accounts is refused only for the auto-add paths: tipping or opening a KaPost written
        // from your second account would otherwise add its author silently, which is how a
        // blank account turned up among the contacts of a real one, reading as a stranger.
        // A deliberate add is different: chatting between your own accounts is a real thing
        // to do (moving funds, trying the app from a fresh account), and the person typing the
        // address knows whose it is.
        let refused = isAutoAdded ? isOwnAccountAddress(address) : isActiveWalletAddress(address)
        guard !refused else {
            // Its own error, not `invalidAddress`: the address is perfectly valid, and telling
            // someone their own address is malformed sends them looking for a typo that is not
            // there. The auto-add callers use `try?`, so for them this is simply a silent skip.
            throw KasiaError.ownAccountAddress
        }

        // A deliberate (non-auto) add explicitly un-does a prior permanent delete's tombstone -
        // the block on auto-recreation is only meant to stop silent resurrection from incoming
        // activity, not to stop the user from choosing to message this address again.
        if !isAutoAdded, deletedAddresses.remove(address) != nil {
            deletedAtByAddress.removeValue(forKey: address)
            deletedTxIdsByAddress.removeValue(forKey: address)
            saveDeletedAddresses()
        }

        // Check for duplicates
        if let existingIndex = contacts.firstIndex(where: { $0.address == address }) {
            if !isAutoAdded && contacts[existingIndex].isAutoAdded {
                contacts[existingIndex].isAutoAdded = false
                let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedAlias.isEmpty {
                    contacts[existingIndex].alias = trimmedAlias
                }
                saveContacts(publishContacts: true)
            }
            return contacts[existingIndex]
        }

        let contact = Contact(
            address: address,
            alias: alias,
            addedAt: Date(),
            isAutoAdded: isAutoAdded
        )

        contacts.append(contact)
        saveContacts()

        return contact
    }

    func updateContact(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
            saveContacts()
        }
    }

    func updateContactLastMessage(_ contactId: UUID, at date: Date) {
        if let index = contacts.firstIndex(where: { $0.id == contactId }) {
            contacts[index].lastMessageAt = date
            scheduleLastMessageSave()
        }
    }

    /// Permanently deletes a contact: purges every local message with them and tombstones their
    /// address so a future incoming message or handshake can't silently recreate the conversation.
    /// Matches Android's `ChatRepository.deleteChat` - not reversible, unlike the old archive.
    func deleteContact(_ contact: Contact) {
        // Your own address is your chat with yourself, which cannot be deleted (see
        // `ChatService.ensureSelfConversation`). A backstop behind the UI, which never offers it.
        if let mine = WalletManager.shared.currentWallet?.publicAddress,
           contact.address.lowercased() == mine.lowercased() {
            return
        }
        deletedAddresses.insert(contact.address)
        // Stamped in the indexer's BLOCK-TIME clock, not the wall clock, and the two are not
        // interchangeable. Mixing them is what Android hit first: a device whose clock runs ahead
        // of the chain stamps a tombstone in the future, and a genuinely new re-handshake arriving
        // before the clocks converge gets dropped as history. So the stamp is the newest block
        // time actually seen in this conversation, and the wall clock is only the fallback for a
        // conversation with nothing in it - where there is no history to suppress anyway.
        let conversationMessages = ChatService.shared.conversations
            .first(where: { $0.contact.address == contact.address })?
            .messages ?? []
        let newestSeen = conversationMessages.map { Int64($0.blockTime) }.max() ?? 0
        let deletedAt = newestSeen > 0 ? newestSeen : Int64(Date().timeIntervalSince1970 * 1000)
        deletedAtByAddress[contact.address] = deletedAt
        // The ids already ours at that instant, so a new transaction sharing it is recognisable.
        deletedTxIdsByAddress[contact.address] = Set(
            conversationMessages.filter { Int64($0.blockTime) == deletedAt }.map(\.txId).filter { !$0.isEmpty }
        )
        saveDeletedAddresses()
        // The contact leaves the list immediately; the store delete runs off the main thread. The
        // `deletedAtByAddress` marker above is what keeps the old history from being re-fetched
        // in the meantime, so nothing depends on the delete having finished first.
        let address = contact.address
        Task { await MessageStore.shared.deleteConversation(contactAddress: address) }
        contacts.removeAll { $0.id == contact.id }
        saveContacts()
    }

    func deleteAllContacts() {
        contacts.removeAll()
        if let contactsKey = activeContactsKey {
            userDefaults.removeObject(forKey: contactsKey)
        } else {
            userDefaults.removeObject(forKey: legacyContactsKey)
        }
        saveContacts()
    }

    func getContact(byAddress address: String) -> Contact? {
        contactsByAddress[address]
    }

    /// The one display-name rule for any Kaspa address, used everywhere a person is named:
    /// the name the user assigned this contact, else their KNS domain, else the short address.
    /// Nothing auto-populates a contact's name, so an address with a domain shows the domain
    /// until the user deliberately renames it. Since 5.2 the KNS step is always empty
    /// (`KNSService.showsDomainNamesAsIdentity`): no assigned name means the address, until
    /// .kachat names exist.
    func displayName(for address: String) -> String {
        if let assigned = getContact(byAddress: address)?.assignedName { return assigned }
        if let saved = AddressBookManager.shared.entry(for: address)?.name { return saved }
        return identityName(for: address)
    }

    /// Same rule, when the caller already has the `Contact` in hand. A name you gave the chat
    /// wins; then the address's Address Book name; then who it is on chain.
    func displayName(for contact: Contact) -> String {
        if let assigned = contact.assignedName { return assigned }
        if let saved = AddressBookManager.shared.entry(for: contact.address)?.name { return saved }
        return identityName(for: contact.address)
    }

    /// Who an address is when you haven't named it yourself. On testnet that is its `.kachat`
    /// name (KACHAT_NAMES.md section 7) - KNS is not consulted there; elsewhere the KNS domain
    /// as before. Otherwise the short address.
    private func identityName(for address: String) -> String {
        if KachatNamesService.isEnabled {
            if let label = KachatNamesRegistry.shared.cachedIdentity(for: address)?.label {
                return "\(label).kachat"
            }
            return Contact.generateDefaultAlias(from: address)
        }
        if let domain = KNSService.shared.profileCache[address]?.domainName, !domain.isEmpty { return domain }
        return Contact.generateDefaultAlias(from: address)
    }

    /// The accepted/established-contact predicate shared by the stranger-gating features:
    /// true for contacts the user added themselves, or ones the user has ever sent a message
    /// to (which includes accepting their handshake - the handshake response IS an outgoing
    /// message). False only for auto-added, never-replied-to strangers. Used by the photo
    /// auto-display gate below and by link-preview auto-fetch gating (Decision 5A).
    func isAcceptedContact(_ contact: Contact) -> Bool {
        !contact.isAutoAdded || contact.hasSentOutgoingMessage
    }

    /// Whether photo bubbles from this contact should auto-decode and render, vs. staying
    /// hidden behind a "Show Photo" tap. Defaults to trusting contacts you added yourself or
    /// have ever messaged; untrusted (auto-added, never-replied-to) contacts are hidden by
    /// default until the user overrides it in Chat Info or disables the setting globally.
    func shouldAutoDisplayPhotos(for contact: Contact, settings: AppSettings) -> Bool {
        switch contact.photoAutoDisplayOverride {
        case .alwaysShow:
            return true
        case .alwaysHide:
            return false
        case .automatic, nil:
            guard settings.requirePhotoApprovalForNewContacts else { return true }
            return isAcceptedContact(contact)
        }
    }

    /// Marks that the user has sent at least one outgoing message to this contact, which
    /// establishes trust for features like photo auto-display even if they were auto-added.
    func markHasSentOutgoingMessage(address: String) {
        guard let index = contacts.firstIndex(where: { $0.address == address }),
              !contacts[index].hasSentOutgoingMessage else { return }
        contacts[index].hasSentOutgoingMessage = true
        saveContacts()
    }

    func getOrCreateContact(address: String, alias: String = "") -> Contact {
        if let existing = getContact(byAddress: address) {
            return existing
        }

        // Auto-add new contact
        let contact = Contact(
            address: address,
            alias: alias,
            addedAt: Date(),
            isAutoAdded: true
        )

        contacts.append(contact)
        saveContacts()

        // Fetch KNS info in background - only while .kas names are shown as names at all.
        if KNSService.showsDomainNamesAsIdentity {
            Task {
                if let knsInfo = await knsService.fetchInfo(for: address),
                   let primaryDomain = knsInfo.primaryDomain {
                    // If the alias is still the auto-generated one, update it to the KNS domain.
                    let autoAlias = Contact.generateDefaultAlias(from: address)
                    if let index = contacts.firstIndex(where: { $0.address == address }),
                       contacts[index].alias == autoAlias {
                        contacts[index].alias = primaryDomain
                        saveContacts(publishContacts: true)
                    }
                }
            }
        }

        return contact
    }

    func searchContacts(_ query: String) -> [Contact] {
        guard !query.isEmpty else { return contacts }

        let lowercasedQuery = query.lowercased()
        return contacts.filter {
            $0.alias.lowercased().contains(lowercasedQuery) ||
            $0.address.lowercased().contains(lowercasedQuery)
        }
    }

    // MARK: - Validation

    func isValidKaspaAddress(_ address: String) -> Bool {
        // Use proper Kaspa bech32 validation
        return KaspaAddress.isValid(address)
    }

    // MARK: - Private Methods

    private func saveContacts(
        syncShared: Bool = true,
        updatePush: Bool = true,
        publishContacts: Bool = false
    ) {
        if publishContacts {
            // Force a @Published emission for in-place element mutations.
            contacts = Array(contacts)
        }

        if let contactsKey = activeContactsKey,
           let data = try? JSONEncoder().encode(contacts) {
            userDefaults.set(data, forKey: contactsKey)
        }

        // Sync contacts to shared container for notification extension
        if syncShared {
            scheduleSharedSync()
        }

        // Update push notification watched addresses
        if updatePush {
            schedulePushUpdate()
        }
    }

    /// True when this address belongs to the user themselves: the wallet in use, or any account
    /// saved on this device.
    ///
    /// Both halves matter. The active wallet is the obvious one; the saved list is the one that
    /// was missing, and it is the one that leaks - a second account is still "you", and adding it
    /// as a contact both clutters the list and invites messaging yourself by a route the app does
    /// not otherwise offer.
    private func isOwnAccountAddress(_ address: String) -> Bool {
        guard let normalized = normalizeWalletAddress(address) else { return false }
        if let activeWalletAddress, activeWalletAddress == normalized { return true }
        return WalletManager.shared.savedAccounts.contains {
            normalizeWalletAddress($0.publicAddress) == normalized
        }
    }

    /// The account in use right now - the one address that can never be a contact of itself.
    private func isActiveWalletAddress(_ address: String) -> Bool {
        guard let normalized = normalizeWalletAddress(address), let activeWalletAddress else { return false }
        return activeWalletAddress == normalized
    }

    private var activeContactsKey: String? {
        guard let activeWalletAddress else { return nil }
        return contactsKey(forNormalizedWalletAddress: activeWalletAddress)
    }

    private func normalizeWalletAddress(_ walletAddress: String?) -> String? {
        guard let walletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !walletAddress.isEmpty else {
            return nil
        }
        return walletAddress.lowercased()
    }

    private func contactsKey(forNormalizedWalletAddress walletAddress: String) -> String {
        let sanitized = walletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(contactsKeyPrefix)\(sanitized)"
    }

    private func deletedAddressesKey(forNormalizedWalletAddress walletAddress: String) -> String {
        let sanitized = walletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(deletedAddressesKeyPrefix)\(sanitized)"
    }

    private func loadDeletedAddresses() {
        guard let activeWalletAddress else {
            deletedAddresses = []
            deletedAtByAddress = [:]
            deletedTxIdsByAddress = [:]
            return
        }
        let key = deletedAddressesKey(forNormalizedWalletAddress: activeWalletAddress)
        deletedAddresses = Set(userDefaults.stringArray(forKey: key) ?? [])

        let atKey = deletedAtKey(forNormalizedWalletAddress: activeWalletAddress)
        var stamps = (userDefaults.dictionary(forKey: atKey) as? [String: NSNumber])?
            .mapValues { $0.int64Value } ?? [:]
        // Tombstones written before deletion times existed carry no timestamp. Stamping them
        // "now" preserves exactly today's behaviour for everything already on chain, while
        // letting anything sent from here on through - which is the whole point.
        var didBackfill = false
        for address in deletedAddresses where stamps[address] == nil {
            stamps[address] = Int64(Date().timeIntervalSince1970 * 1000)
            didBackfill = true
        }
        deletedAtByAddress = stamps

        // Tombstones written before the tie-breaker existed have no entry here at all, and
        // `isDeletedAsOf` suppresses on the deletion instant when that is the case. Those stamps
        // were `max(wall clock, newest block time)`, so the instant can genuinely BE a message of
        // ours - suppressing it is the correct reading. An entry that exists but is empty means
        // the conversation had nothing in it, and anything sharing that instant is new.
        let txKey = deletedTxIdsKey(forNormalizedWalletAddress: activeWalletAddress)
        deletedTxIdsByAddress = (userDefaults.dictionary(forKey: txKey) as? [String: [String]])?
            .mapValues { Set($0) } ?? [:]

        if didBackfill { saveDeletedAddresses() }
    }

    private func saveDeletedAddresses() {
        guard let activeWalletAddress else { return }
        let key = deletedAddressesKey(forNormalizedWalletAddress: activeWalletAddress)
        userDefaults.set(Array(deletedAddresses), forKey: key)
        let atKey = deletedAtKey(forNormalizedWalletAddress: activeWalletAddress)
        userDefaults.set(deletedAtByAddress.mapValues { NSNumber(value: $0) }, forKey: atKey)
        let txKey = deletedTxIdsKey(forNormalizedWalletAddress: activeWalletAddress)
        userDefaults.set(deletedTxIdsByAddress.mapValues { Array($0) }, forKey: txKey)
    }

    private func deletedTxIdsKey(forNormalizedWalletAddress walletAddress: String) -> String {
        let sanitized = walletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(deletedTxIdsKeyPrefix)\(sanitized)"
    }

    private func deletedAtKey(forNormalizedWalletAddress walletAddress: String) -> String {
        let sanitized = walletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(deletedAtKeyPrefix)\(sanitized)"
    }

    private func sortContacts(_ list: [Contact]) -> [Contact] {
        list.sorted { ($0.lastMessageAt ?? $0.addedAt) > ($1.lastMessageAt ?? $1.addedAt) }
    }

    private func cancelPendingSaves() {
        lastMessageSaveWorkItem?.cancel()
        lastMessageSaveWorkItem = nil
        sharedSyncWorkItem?.cancel()
        sharedSyncWorkItem = nil
        pushUpdateWorkItem?.cancel()
        pushUpdateWorkItem = nil
    }

    private func scheduleLastMessageSave() {
        lastMessageSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveContacts(syncShared: false, updatePush: false)
        }
        lastMessageSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + lastMessageSaveDelay, execute: workItem)
    }

    private func scheduleSharedSync() {
        sharedSyncWorkItem?.cancel()
        let now = Date()
        let timeSinceLast = lastSharedSyncAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let minDelay = max(sharedSyncDelay, minSharedSyncInterval - timeSinceLast)
        let delay = max(sharedSyncDelay, minDelay)
        let workItem = DispatchWorkItem { [weak self] in
            self?.lastSharedSyncAt = Date()
            SharedDataManager.syncContactsForExtension()
        }
        sharedSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func schedulePushUpdate() {
        pushUpdateWorkItem?.cancel()
        let now = Date()
        let timeSinceLast = lastPushUpdateAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let minDelay = max(pushUpdateDelay, minPushUpdateInterval - timeSinceLast)
        let delay = max(pushUpdateDelay, minDelay)
        let workItem = DispatchWorkItem { [weak self] in
            self?.lastPushUpdateAt = Date()
            Task {
                await PushNotificationManager.shared.updateWatchedAddresses()
            }
        }
        pushUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
