import Foundation
import Contacts
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
    @Published private(set) var systemContactsAuthorized = false
    @Published private(set) var systemContactCandidates: [SystemContactCandidate] = []

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
    private let systemContactsService = SystemContactsService.shared
    private var balanceFetchInFlight: Set<String> = []
    private var balanceLastFetch: [String: Date] = [:]
    private let balanceMinInterval: TimeInterval = 30.0
    private var lastSystemContactsRefreshAt: Date?
    private let systemContactsRefreshMinInterval: TimeInterval = 600.0
    private let systemContactLinkTargetsTimeout: TimeInterval = 8.0
    private let systemContactLinkWriteTimeout: TimeInterval = 6.0
    private var syncSystemContactsEnabled = AppSettings.load().syncSystemContacts
    private var didBootstrapSystemContacts = false
    private var settingsObserver: NSObjectProtocol?
    private var isSystemContactRefreshInProgress = false
    private var queuedSystemContactRefresh: (promptIfNeeded: Bool, force: Bool)?
    private let allowAutomaticSystemContactWrites: Bool = {
#if targetEnvironment(macCatalyst)
        false
#else
        true
#endif
    }()

    private init() {
        contacts = []
        observeSettingsChanges()
        Task {
            await updateSystemContactsAuthorization()
            guard syncSystemContactsEnabled else {
                systemContactCandidates = []
                return
            }
            await refreshSystemContactLinks(promptIfNeeded: false, force: false)
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
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
        // unnamed one stays unnamed and resolves through `displayName(for:)` instead - and a
        // linked iCloud contact name is never overwritten (system contact takes priority).
        for contact in contacts {
            if let knsInfo = knsService.domainCache[contact.address],
               let primaryDomain = knsInfo.primaryDomain {
                // Skip KNS alias update if contact has a linked system contact name
                if contact.systemContactId != nil,
                   let snapshot = contact.systemDisplayNameSnapshot,
                   !snapshot.isEmpty,
                   contact.alias == snapshot {
                    continue
                }
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

        // Also repair linked system contact URL entries immediately using normalized KNS domains.
        // This fixes legacy values like "http://name.kas" without waiting for periodic refresh.
        // Skip this automatic write loop on macOS Catalyst to avoid contactd CPU spikes.
        if allowAutomaticSystemContactWrites {
            var didClearStaleLinks = false
            for contact in contacts {
                guard let linkedId = contact.systemContactId else { continue }
                guard let info = knsService.domainCache[contact.address] else { continue }
                let domains = info.allDomains.map { $0.fullName }
                do {
                    let didUpsert = try await systemContactsService.upsertKaChatData(
                        contactIdentifier: linkedId,
                        address: contact.address,
                        domains: domains,
                        appContactId: contact.id,
                        autoCreated: contact.systemContactLinkSource == .autoCreated
                    )
                    if !didUpsert,
                       clearStaleSystemContactLink(
                        contactId: contact.id,
                        expectedContactIdentifier: linkedId
                       ) {
                        didClearStaleLinks = true
                    }
                } catch {
                    // Best effort only.
                }
            }
            if didClearStaleLinks {
                saveContacts(syncShared: true, updatePush: false, publishContacts: true)
            }
        }
    }

    /// Get KNS info for a contact
    func getKNSInfo(for contact: Contact) -> KNSAddressInfo? {
        return knsService.domainCache[contact.address]
    }

    /// Get KNS domains for a contact
    func getKNSDomains(for contact: Contact) -> [KNSDomain] {
        return knsService.domainCache[contact.address]?.allDomains ?? []
    }

    /// Get selected KNS profile for a contact address (primary domain if available).
    func getKNSProfile(for contact: Contact) -> KNSAddressProfileInfo? {
        knsService.profileCache[contact.address]
    }

    /// Fetch KNS info for a specific contact
    func fetchKNSInfo(for contact: Contact, network: NetworkType = .mainnet) async -> KNSAddressInfo? {
        await knsService.fetchInfo(for: contact.address, network: network)
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
        loadDeletedAddresses()

        if normalizedAddress == nil {
            systemContactCandidates = []
            SharedDataManager.syncContactsForExtension()
            return
        }

        Task {
            await refreshSystemContactLinks(promptIfNeeded: false, force: true)
        }
    }

    func clearInMemoryContacts(syncShared: Bool = true, updatePush: Bool = false) {
        cancelPendingSaves()
        contacts = []
        contactBalances = [:]
        balanceLastFetch = [:]
        balanceFetchInFlight = []
        systemContactCandidates = []
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
            contacts = sortContacts(migrateLegacyDefaultAliases(decodedContacts, contactsKey: contactsKey))
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

    func addContact(address: String, alias: String = "", isAutoAdded: Bool = false) throws -> Contact {
        // Validate address format
        guard isValidKaspaAddress(address) else {
            throw KasiaError.invalidAddress
        }

        // Never one of the user's OWN accounts. Nothing stopped this before, so an address the
        // user owns on another account could land in this account's contact list and read as a
        // stranger - which is how a blank account turned up among the contacts of a real one.
        // The auto-add paths make it easy to hit without noticing: tipping or opening a KaPost
        // written from your own second account adds its author silently.
        guard !isOwnAccountAddress(address) else {
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
        Task {
            await refreshSystemContactLinks(promptIfNeeded: false, force: false)
        }

        return contact
    }

    func updateContact(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            let previous = contacts[index]
            contacts[index] = contact
            saveContacts()

            // Sync name change only to auto-created shadow contacts while auto-create is enabled.
            if contact.alias != previous.alias,
               let sysId = contact.systemContactId,
               contact.systemContactLinkSource == .autoCreated,
               allowAutomaticSystemContactWrites {
                Task {
                    try? await systemContactsService.updateAutoCreatedContactName(
                        contactIdentifier: sysId,
                        newName: contact.alias
                    )
                }
            }
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
        SystemContactAvatarStore.shared.removeCachedPhoto(forSystemContactId: contact.systemContactId)
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
    /// until the user deliberately renames it.
    func displayName(for address: String) -> String {
        if let assigned = getContact(byAddress: address)?.assignedName { return assigned }
        if let domain = KNSService.shared.profileCache[address]?.domainName, !domain.isEmpty { return domain }
        return Contact.generateDefaultAlias(from: address)
    }

    /// Same rule, when the caller already has the `Contact` in hand.
    func displayName(for contact: Contact) -> String {
        if let assigned = contact.assignedName { return assigned }
        if let domain = KNSService.shared.profileCache[contact.address]?.domainName, !domain.isEmpty { return domain }
        return Contact.generateDefaultAlias(from: contact.address)
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
        Task {
            await refreshSystemContactLinks(promptIfNeeded: false, force: false)
        }

        // Fetch KNS info in background
        Task {
            if let knsInfo = await knsService.fetchInfo(for: address),
               let primaryDomain = knsInfo.primaryDomain {
                // If alias is auto-generated AND no system contact linked, update to KNS domain.
                // iCloud contact name takes priority over KNS domain.
                let autoAlias = Contact.generateDefaultAlias(from: address)
                if let index = contacts.firstIndex(where: { $0.address == address }),
                   contacts[index].alias == autoAlias,
                   contacts[index].systemContactId == nil {
                    contacts[index].alias = primaryDomain
                    saveContacts(publishContacts: true)
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

    // MARK: - System Contacts Integration

    func requestSystemContactsAccess() async -> Bool {
        guard syncSystemContactsEnabled else {
            systemContactCandidates = []
            return false
        }
        let granted = await systemContactsService.requestAccessIfNeeded()
        await updateSystemContactsAuthorization()
        if granted {
            _ = await loadSystemContactCandidates(promptIfNeeded: false)
            await refreshSystemContactLinks(promptIfNeeded: false, force: true)
        }
        return granted
    }

    func bootstrapSystemContactsIfNeeded() async {
        guard !didBootstrapSystemContacts else { return }
        didBootstrapSystemContacts = true

        guard syncSystemContactsEnabled else {
            systemContactCandidates = []
            await updateSystemContactsAuthorization()
            return
        }

        let status = await systemContactsService.authorizationStatus()
        if status == .notDetermined {
            _ = await systemContactsService.requestAccessIfNeeded()
        }
        await updateSystemContactsAuthorization()

        guard systemContactsAuthorized else {
            systemContactCandidates = []
            return
        }

        await refreshSystemContactLinks(promptIfNeeded: false, force: true)
        // Links are settled: pull the Contacts-app photos for everyone now linked so the
        // avatar fallback (KNS avatar -> device photo -> glyph) has them ready.
        SystemContactAvatarStore.shared.prefetchPhotos(for: contacts)
    }

    func loadSystemContactCandidates(promptIfNeeded: Bool = false) async -> [SystemContactCandidate] {
        guard syncSystemContactsEnabled else {
            systemContactCandidates = []
            return []
        }

        if promptIfNeeded {
            let granted = await systemContactsService.requestAccessIfNeeded()
            await updateSystemContactsAuthorization()
            guard granted else {
                systemContactCandidates = []
                return []
            }
        } else {
            await updateSystemContactsAuthorization()
            guard systemContactsAuthorized else {
                systemContactCandidates = []
                return []
            }
        }

        do {
            let candidates = try await systemContactsService.fetchCandidates()
            systemContactCandidates = candidates
            return candidates
        } catch {
            systemContactCandidates = []
            return []
        }
    }

    func loadSystemContactLinkTargets(promptIfNeeded: Bool = false) async -> [SystemContactLinkTarget] {
        guard syncSystemContactsEnabled else { return [] }

        if promptIfNeeded {
            let granted = await systemContactsService.requestAccessIfNeeded()
            await updateSystemContactsAuthorization()
            guard granted else { return [] }
        } else {
            await updateSystemContactsAuthorization()
            guard systemContactsAuthorized else { return [] }
        }

        do {
            return try await runWithTimeout(
                seconds: systemContactLinkTargetsTimeout,
                operation: "fetchLinkTargets"
            ) { [systemContactsService] in
                try await systemContactsService.fetchLinkTargets()
            }
        } catch {
            AppLog.log("[ContactsManager] Failed to load system contact link targets: %@", error.localizedDescription)
            return []
        }
    }

    func refreshSystemContactLinks(promptIfNeeded: Bool = false, force: Bool = false) async {
        if let queued = queuedSystemContactRefresh {
            queuedSystemContactRefresh = (
                promptIfNeeded: queued.promptIfNeeded || promptIfNeeded,
                force: queued.force || force
            )
        } else {
            queuedSystemContactRefresh = (promptIfNeeded: promptIfNeeded, force: force)
        }

        guard !isSystemContactRefreshInProgress else { return }
        isSystemContactRefreshInProgress = true
        defer { isSystemContactRefreshInProgress = false }

        while let request = queuedSystemContactRefresh {
            queuedSystemContactRefresh = nil
            await performSystemContactLinksRefresh(
                promptIfNeeded: request.promptIfNeeded,
                force: request.force
            )
        }
    }

    private func performSystemContactLinksRefresh(promptIfNeeded: Bool = false, force: Bool = false) async {
        guard syncSystemContactsEnabled else {
            systemContactCandidates = []
            return
        }
        guard !contacts.isEmpty else { return }

        let now = Date()
        if !force, let last = lastSystemContactsRefreshAt, now.timeIntervalSince(last) < systemContactsRefreshMinInterval {
            return
        }

        let candidates = await loadSystemContactCandidates(promptIfNeeded: promptIfNeeded)

        var contactsByAddress: [String: SystemContactCandidate] = [:]
        for candidate in candidates {
            contactsByAddress[candidate.address.lowercased()] = candidate
        }

        var updated = false
        var staleAutoCreatedIds: [(contactIdentifier: String, appContactId: UUID)] = []
        let contactIds = contacts.map(\.id)
        for contactId in contactIds {
            guard let index = contacts.firstIndex(where: { $0.id == contactId }) else { continue }
            let current = contacts[index]

            let addressKey = current.address.lowercased()
            if let candidate = contactsByAddress[addressKey] {
                if current.systemContactId != candidate.contactIdentifier ||
                    current.systemDisplayNameSnapshot != candidate.displayName ||
                    current.systemMatchConfidence != 1.0 {
                    // Track old auto-created contact for cleanup when re-linking to a different one.
                    if let previousId = current.systemContactId,
                       previousId != candidate.contactIdentifier,
                       current.systemContactLinkSource == .autoCreated {
                        staleAutoCreatedIds.append((contactIdentifier: previousId, appContactId: current.id))
                    }
                    contacts[index].systemContactId = candidate.contactIdentifier
                    contacts[index].systemDisplayNameSnapshot = candidate.displayName
                    if candidate.isAutoCreated {
                        contacts[index].systemContactLinkSource = .autoCreated
                    } else if current.systemContactId != candidate.contactIdentifier {
                        contacts[index].systemContactLinkSource = .matched
                    }
                    contacts[index].systemMatchConfidence = 1.0
                    contacts[index].systemLastSyncedAt = now
                    updated = true
                }

                // Correct source if it drifted (e.g. previously corrupted to .matched).
                if candidate.isAutoCreated,
                   contacts[index].systemContactLinkSource != .autoCreated {
                    contacts[index].systemContactLinkSource = .autoCreated
                    updated = true
                } else if !candidate.isAutoCreated,
                          contacts[index].systemContactLinkSource == .autoCreated {
                    contacts[index].systemContactLinkSource = .matched
                    updated = true
                }

                // Auto-created contacts mirror the app alias, so don't adopt their name back.
                if !candidate.isAutoCreated {
                    let autoAlias = Contact.generateDefaultAlias(from: current.address)
                    let trimmedAlias = current.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    // iCloud contact name takes priority over auto-generated aliases AND KNS domain names
                    let isAutoOrKNS = trimmedAlias.isEmpty || trimmedAlias == autoAlias || trimmedAlias.lowercased().hasSuffix(".kas")
                    if isAutoOrKNS {
                        if contacts[index].alias != candidate.displayName {
                            contacts[index].alias = candidate.displayName
                            updated = true
                        }
                    }
                }
            }

            // Keep linked system contact metadata canonicalized and up to date.
            // This also repairs legacy URL entries like "http://name" -> "name.kas".
            guard let latestIndex = contacts.firstIndex(where: { $0.id == contactId }) else { continue }
            let latest = contacts[latestIndex]
            if allowAutomaticSystemContactWrites, let linkedId = latest.systemContactId {
                let domains = getKNSInfo(for: latest)?.allDomains.map { $0.fullName } ?? []
                do {
                    let didUpsert = try await systemContactsService.upsertKaChatData(
                        contactIdentifier: linkedId,
                        address: latest.address,
                        domains: domains,
                        appContactId: latest.id,
                        autoCreated: latest.systemContactLinkSource == .autoCreated
                    )
                    if !didUpsert,
                       clearStaleSystemContactLink(
                        contactId: latest.id,
                        expectedContactIdentifier: linkedId,
                        at: now
                       ) {
                        updated = true
                    }
                } catch {
                    // Best effort only.
                }
            }
        }

        lastSystemContactsRefreshAt = now
        if updated {
            saveContacts(syncShared: true, updatePush: false, publishContacts: true)
        }

        // Clean up stale auto-created contacts that were replaced by a different match.
        if allowAutomaticSystemContactWrites {
            for stale in staleAutoCreatedIds {
                _ = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                    contactIdentifier: stale.contactIdentifier,
                    appContactId: stale.appContactId
                )
            }
        }

        // Remove any orphaned auto-created contacts not actively linked.
        var activeLinks: [String: String] = [:]
        for contact in contacts {
            if contact.systemContactLinkSource == .autoCreated,
               let sysId = contact.systemContactId {
                activeLinks[sysId] = contact.address.lowercased()
            }
        }
        if allowAutomaticSystemContactWrites && (!activeLinks.isEmpty || force) {
            let removed = await systemContactsService.removeOrphanedAutoCreatedContacts(activeLinks: activeLinks)
            if removed > 0 {
                AppLog.log("[ContactsManager] Removed %d orphaned auto-created system contacts", removed)
            }
        }
    }

    func linkContact(_ contact: Contact, to candidate: SystemContactCandidate, updateAlias: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        let current = contacts[index]
        let autoAlias = Contact.generateDefaultAlias(from: current.address)
        let trimmedAlias = current.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        // iCloud contact name takes priority over auto-generated aliases and KNS domain names
        let shouldAdoptSystemName = updateAlias || trimmedAlias.isEmpty || trimmedAlias == autoAlias || trimmedAlias.lowercased().hasSuffix(".kas")
        let previousId = contacts[index].systemContactId
        contacts[index].systemContactId = candidate.contactIdentifier
        contacts[index].systemDisplayNameSnapshot = candidate.displayName
        contacts[index].systemContactLinkSource = .manual
        contacts[index].systemMatchConfidence = 1.0
        contacts[index].systemLastSyncedAt = Date()
        if shouldAdoptSystemName {
            contacts[index].alias = candidate.displayName
        }
        saveContacts(syncShared: true, updatePush: false, publishContacts: true)

        // Clean up old auto-created contact when re-linking to a real one.
        if let previousId, previousId != candidate.contactIdentifier {
            Task {
                let deleted = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                    contactIdentifier: previousId,
                    appContactId: contact.id
                )
                if deleted != true {
                    // Marker may have been lost; strip Kaspa data to prevent re-matching.
                    try? await systemContactsService.removeKaChatData(
                        contactIdentifier: previousId
                    )
                }
            }
        }
    }

    func linkContactToSystemContact(
        _ contact: Contact,
        target: SystemContactLinkTarget,
        updateAlias: Bool
    ) async throws {
        guard syncSystemContactsEnabled else {
            throw KasiaError.apiError("System contacts sync is disabled")
        }

        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        let current = contacts[index]
        let autoAlias = Contact.generateDefaultAlias(from: current.address)
        let trimmedAlias = current.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        // iCloud contact name takes priority over auto-generated aliases and KNS domain names
        let shouldAdoptSystemName = updateAlias || trimmedAlias.isEmpty || trimmedAlias == autoAlias || trimmedAlias.lowercased().hasSuffix(".kas")
        let previousId = contacts[index].systemContactId
        contacts[index].systemContactId = target.contactIdentifier
        contacts[index].systemDisplayNameSnapshot = target.displayName
        contacts[index].systemContactLinkSource = .manual
        contacts[index].systemMatchConfidence = 1.0
        contacts[index].systemLastSyncedAt = Date()
        if shouldAdoptSystemName {
            contacts[index].alias = target.displayName
        }
        saveContacts(syncShared: true, updatePush: false, publishContacts: true)

        // External system-contact write is best effort on mac where CNContactStore calls can stall.
        let info = await fetchKNSInfo(for: contact)
        let domains = info?.allDomains.map { $0.fullName } ?? []
        do {
            let didUpsert = try await runWithTimeout(
                seconds: systemContactLinkWriteTimeout,
                operation: "upsertKaChatData"
            ) { [systemContactsService] in
                try await systemContactsService.upsertKaChatData(
                    contactIdentifier: target.contactIdentifier,
                    address: contact.address,
                    domains: domains,
                    appContactId: contact.id,
                    autoCreated: false
                )
            }
            if !didUpsert,
               clearStaleSystemContactLink(
                contactId: contact.id,
                expectedContactIdentifier: target.contactIdentifier
               ) {
                saveContacts(syncShared: true, updatePush: false, publishContacts: true)
            }
        } catch {
            AppLog.log("[ContactsManager] Failed to write KaChat metadata to system contact %@: %@",
                  target.contactIdentifier, error.localizedDescription)
        }

        // Clean up old auto-created contact when re-linking to a real one.
        if let previousId, previousId != target.contactIdentifier {
            let deleted = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                contactIdentifier: previousId,
                appContactId: contact.id
            )
            if deleted != true {
                // Marker may have been lost; strip Kaspa data to prevent re-matching.
                try? await systemContactsService.removeKaChatData(
                    contactIdentifier: previousId
                )
            }
        }
    }

    @discardableResult
    private func clearStaleSystemContactLink(
        contactId: UUID,
        expectedContactIdentifier: String,
        at date: Date = Date()
    ) -> Bool {
        guard let index = contacts.firstIndex(where: { $0.id == contactId }) else { return false }
        guard contacts[index].systemContactId == expectedContactIdentifier else { return false }

        contacts[index].systemContactId = nil
        contacts[index].systemDisplayNameSnapshot = nil
        contacts[index].systemContactLinkSource = nil
        contacts[index].systemMatchConfidence = nil
        contacts[index].systemLastSyncedAt = date
        return true
    }

    func unlinkSystemContact(_ contact: Contact) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        let previousId = contacts[index].systemContactId
        let previousSource = contacts[index].systemContactLinkSource
        contacts[index].systemContactId = nil
        contacts[index].systemDisplayNameSnapshot = nil
        contacts[index].systemContactLinkSource = nil
        contacts[index].systemMatchConfidence = nil
        contacts[index].systemLastSyncedAt = Date()
        saveContacts(syncShared: true, updatePush: false, publishContacts: true)
        SystemContactAvatarStore.shared.removeCachedPhoto(forSystemContactId: previousId)

        let contactId = contact.id
        Task {
            if let previousId {
                if previousSource == .autoCreated {
                    // Delete the old auto-created shadow entirely.
                    _ = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                        contactIdentifier: previousId,
                        appContactId: contactId
                    )
                } else {
                    // Real system contact: strip Kaspa data so it won't be re-matched.
                    try? await systemContactsService.removeKaChatData(
                        contactIdentifier: previousId
                    )
                }
            }
        }
    }

    /// Manual "Create System Contact" (Chat Info): creates a dedicated entry in the iOS
    /// Contacts app for this KaChat contact and links it. Replaces the removed auto-create
    /// setting - system-contact creation is user-initiated per contact now.
    func createSystemContact(for contact: Contact) async -> Contact? {
        guard contact.systemContactId == nil else { return nil }
        guard await systemContactsService.requestAccessIfNeeded() else { return nil }
        await updateSystemContactsAuthorization()
        let domains = await fetchKNSInfo(for: contact)?.allDomains.map { $0.fullName } ?? []
        do {
            let created = try await systemContactsService.createKaChatContact(
                displayName: contact.alias,
                address: contact.address,
                domains: domains,
                appContactId: contact.id
            )
            guard !created.contactIdentifier.isEmpty,
                  let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return nil }
            contacts[index].systemContactId = created.contactIdentifier
            contacts[index].systemDisplayNameSnapshot = created.displayName
            contacts[index].systemContactLinkSource = .autoCreated
            contacts[index].systemMatchConfidence = 1.0
            contacts[index].systemLastSyncedAt = Date()
            saveContacts(syncShared: true, updatePush: false, publishContacts: true)
            return contacts[index]
        } catch {
            return nil
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

    private func updateSystemContactsAuthorization() async {
        let status = await systemContactsService.authorizationStatus()
        systemContactsAuthorized = (status == .authorized)
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let settings = notification.object as? AppSettings else { return }
            Task { @MainActor [weak self] in
                self?.applySystemContactsSetting(syncEnabled: settings.syncSystemContacts)
            }
        }
    }

    private func applySystemContactsSetting(syncEnabled: Bool) {
        syncSystemContactsEnabled = syncEnabled
        if !syncEnabled {
            systemContactCandidates = []
        }
    }

    private struct ContactOperationTimeoutError: LocalizedError {
        let operation: String
        let seconds: TimeInterval

        var errorDescription: String? {
            "\(operation) timed out after \(Int(seconds))s"
        }
    }

    private func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) {
                try await work()
            }
            group.addTask(priority: .utility) {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ContactOperationTimeoutError(operation: operation, seconds: seconds)
            }

            guard let first = try await group.next() else {
                throw ContactOperationTimeoutError(operation: operation, seconds: seconds)
            }
            group.cancelAll()
            return first
        }
    }
}

actor SystemContactsService {
    static let shared = SystemContactsService()

    private let store = CNContactStore()
    private let contactStoreQueue = DispatchQueue(
        label: "com.kachat.system-contacts-store",
        // CNContactStore internally relies on lower-priority AddressBook threads on macOS.
        // Running our wrapper queue at utility avoids QoS inversion warnings.
        qos: .utility
    )
    private let kaspaURLLabel = "Kaspa"
    private let kaChatURLLabel = "KaChat"
    private let kaChatAutoMarkerPrefix = "kachat:auto:"
    private let knsInstantMessageService = "KNS"
    private let addressRegex: NSRegularExpression? = {
        // Kaspa addresses are lowercase bech32-like strings; match both mainnet and testnet prefixes.
        let pattern = "(kaspa:[a-z0-9]{20,}|kaspatest:[a-z0-9]{20,})"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private func performStoreOperation<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            contactStoreQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func isMissingRecordError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CNErrorDomain && nsError.code == 200
    }

    func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccessIfNeeded() async -> Bool {
        let status = authorizationStatus()
        if status == .authorized {
            return true
        }
        guard status == .notDetermined else {
            return false
        }

        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func fetchCandidates() async throws -> [SystemContactCandidate] {
        // Main path: request both name + address-like fields in one pass.
        // Fallback path below drops name keys if profile-level access is restricted.
        let richKeys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        return try await performStoreOperation { [self] in
            do {
                return try self.buildCandidates(keys: richKeys, includeDisplayName: true)
            } catch {
                let nsError = error as NSError
                // Some device profiles deny subsets of keys. Retry with address-only keys.
                if nsError.domain == CNErrorDomain, nsError.code == 102 {
                    let minimalKeys: [CNKeyDescriptor] = [
                        CNContactIdentifierKey as CNKeyDescriptor,
                        CNContactUrlAddressesKey as CNKeyDescriptor,
                        CNContactEmailAddressesKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor
                    ]
                    return try self.buildCandidates(keys: minimalKeys, includeDisplayName: false)
                }
                throw error
            }
        }
    }

    func fetchLinkTargets() async throws -> [SystemContactLinkTarget] {
        try await performStoreOperation { [self] in
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactMiddleNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactUrlAddressesKey as CNKeyDescriptor
            ]

            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = false

            var targets: [SystemContactLinkTarget] = []
            try store.enumerateContacts(with: request) { [self] contact, _ in
                guard contact.isKeyAvailable(CNContactIdentifierKey) else { return }
                let contactIdentifier = contact.identifier
                guard !contactIdentifier.isEmpty else { return }

                // Skip auto-created KaChat contacts — they're shadow contacts for sync,
                // not real contacts the user should link to.
                if contact.isKeyAvailable(CNContactUrlAddressesKey) {
                    let isAutoCreated = contact.urlAddresses.contains {
                        ($0.value as String).lowercased().hasPrefix(self.kaChatAutoMarkerPrefix)
                    }
                    if isAutoCreated { return }
                }

                targets.append(
                    SystemContactLinkTarget(
                        contactIdentifier: contactIdentifier,
                        displayName: self.preferredDisplayName(for: contact)
                    )
                )
            }

            return targets.sorted { lhs, rhs in
                if lhs.displayName == rhs.displayName {
                    return lhs.contactIdentifier < rhs.contactIdentifier
                }
                return lhs.displayName < rhs.displayName
            }
        }
    }

    private func buildCandidates(keys: [CNKeyDescriptor], includeDisplayName: Bool) throws -> [SystemContactCandidate] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = false

        var byAddress: [String: SystemContactCandidate] = [:]
        try store.enumerateContacts(with: request) { [self] contact, _ in
            guard contact.isKeyAvailable(CNContactIdentifierKey) else { return }
            let contactIdentifier = contact.identifier
            guard !contactIdentifier.isEmpty else { return }

            var addressSources: [String] = []
            if contact.isKeyAvailable(CNContactUrlAddressesKey) {
                addressSources += contact.urlAddresses.map { $0.value as String }
            }
            if contact.isKeyAvailable(CNContactEmailAddressesKey) {
                addressSources += contact.emailAddresses.map { String($0.value) }
            }
            if contact.isKeyAvailable(CNContactPhoneNumbersKey) {
                addressSources += contact.phoneNumbers.map { $0.value.stringValue }
            }

            let displayName = includeDisplayName ? self.preferredDisplayName(for: contact) : "System Contact"
            let hasAutoMarker: Bool = contact.isKeyAvailable(CNContactUrlAddressesKey)
                && contact.urlAddresses.contains {
                    ($0.value as String).lowercased().hasPrefix(self.kaChatAutoMarkerPrefix)
                }
            let extracted = self.extractKaspaAddresses(from: addressSources)
            for address in extracted {
                let candidate = SystemContactCandidate(
                    contactIdentifier: contactIdentifier,
                    displayName: displayName,
                    address: address,
                    sourceHint: nil,
                    isAutoCreated: hasAutoMarker
                )

                // Keep richer name if same Kaspa address appears in multiple contacts.
                if let existing = byAddress[address], existing.displayName.count >= candidate.displayName.count {
                    continue
                }
                byAddress[address] = candidate
            }
        }

        return Array(byAddress.values).sorted { lhs, rhs in
            if lhs.displayName == rhs.displayName {
                return lhs.address < rhs.address
            }
            return lhs.displayName < rhs.displayName
        }
    }

    func upsertKaChatData(
        contactIdentifier: String,
        address: String,
        domains: [String],
        appContactId: UUID? = nil,
        autoCreated: Bool = false
    ) async throws -> Bool {
        do {
            try await performStoreOperation { [self] in
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor,
                    CNContactInstantMessageAddressesKey as CNKeyDescriptor
                ]
                let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
                guard let mutable = contact.mutableCopy() as? CNMutableContact else { return }

                // Canonicalize existing Kaspa-labeled values so stale formats like
                // "http://name.kas" are cleaned up from URL fields.
                // KNS domains are stored as plain ".kas" in Instant Message entries (service: KNS).
                var normalizedURLAddresses: [CNLabeledValue<NSString>] = []
                var seenKaspaAddresses = Set<String>()
                for entry in mutable.urlAddresses {
                    let raw = String(entry.value).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowered = raw.lowercased()

                    // Remove auto markers here; we'll re-add if needed below.
                    if lowered.hasPrefix(kaChatAutoMarkerPrefix) {
                        continue
                    }

                    // Canonicalize not only explicit Kaspa-labeled values, but also legacy/non-Kaspa
                    // URL entries that clearly hold KNS domains (e.g. "http://name.kas").
                    if (entry.label == kaspaURLLabel || lowered.contains(".kas")),
                       let canonical = self.canonicalKaspaValue(from: raw) {
                        // Keep Kaspa addresses in URL fields, but drop KNS domains from URL fields.
                        if KaspaAddress.isValid(canonical), seenKaspaAddresses.insert(canonical).inserted {
                            normalizedURLAddresses.append(
                                CNLabeledValue(label: kaspaURLLabel, value: canonical as NSString)
                            )
                        }
                        continue
                    }

                    normalizedURLAddresses.append(entry)
                }
                mutable.urlAddresses = normalizedURLAddresses

                let kaspaValue = address.lowercased()
                var existingURLValues = Set(
                    mutable.urlAddresses.map {
                        String($0.value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                )
                if !existingURLValues.contains(kaspaValue) {
                    mutable.urlAddresses.append(CNLabeledValue(label: kaspaURLLabel, value: kaspaValue as NSString))
                    existingURLValues.insert(kaspaValue)
                }

                let autoMarkers = mutable.urlAddresses
                    .map { String($0.value).lowercased() }
                    .filter { $0.hasPrefix(kaChatAutoMarkerPrefix) }
                if !autoMarkers.isEmpty {
                    mutable.urlAddresses.removeAll {
                        let value = String($0.value).lowercased()
                        return value.hasPrefix(kaChatAutoMarkerPrefix)
                    }
                    existingURLValues.subtract(autoMarkers)
                }

                // Store KNS domains in IM entries (service: KNS) to prevent URL scheme coercion.
                var normalizedIMAddresses: [CNLabeledValue<CNInstantMessageAddress>] = []
                for entry in mutable.instantMessageAddresses {
                    if entry.value.service.lowercased() == knsInstantMessageService.lowercased() {
                        continue
                    }
                    normalizedIMAddresses.append(entry)
                }
                let normalizedDomains = Array(Set(domains.compactMap(self.normalizeKnsDomain))).sorted()
                for domain in normalizedDomains {
                    let im = CNInstantMessageAddress(username: domain, service: knsInstantMessageService)
                    normalizedIMAddresses.append(CNLabeledValue(label: kaspaURLLabel, value: im))
                }
                mutable.instantMessageAddresses = normalizedIMAddresses

                if autoCreated, let appContactId {
                    let marker = kaChatAutoMarkerPrefix + appContactId.uuidString.lowercased()
                    if !existingURLValues.contains(marker) {
                        mutable.urlAddresses.append(CNLabeledValue(label: kaChatURLLabel, value: marker as NSString))
                        existingURLValues.insert(marker)
                    }
                }

                let request = CNSaveRequest()
                request.update(mutable)
                try store.execute(request)
            }
            return true
        } catch {
            if isMissingRecordError(error) {
                return false
            }
            throw error
        }
    }

    func createKaChatContact(
        displayName: String,
        address: String,
        domains: [String],
        appContactId: UUID
    ) async throws -> SystemContactLinkTarget {
        try await performStoreOperation { [self] in
            let mutable = CNMutableContact()
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            mutable.givenName = trimmed.isEmpty ? "Kaspa Contact" : trimmed
            mutable.organizationName = "KaChat"
            mutable.note = "Auto-managed by KaChat"

            let kaspaValue = address.lowercased()
            mutable.urlAddresses.append(CNLabeledValue(label: kaspaURLLabel, value: kaspaValue as NSString))
            let normalizedDomains = Array(Set(domains.compactMap(self.normalizeKnsDomain))).sorted()
            for domain in normalizedDomains {
                let im = CNInstantMessageAddress(username: domain, service: knsInstantMessageService)
                mutable.instantMessageAddresses.append(CNLabeledValue(label: kaspaURLLabel, value: im))
            }

            let marker = kaChatAutoMarkerPrefix + appContactId.uuidString.lowercased()
            mutable.urlAddresses.append(CNLabeledValue(label: kaChatURLLabel, value: marker as NSString))

            let request = CNSaveRequest()
            request.add(mutable, toContainerWithIdentifier: nil)
            try store.execute(request)

            let contactIdentifier = mutable.identifier
            if contactIdentifier.isEmpty {
                return SystemContactLinkTarget(
                    contactIdentifier: "",
                    displayName: trimmed.isEmpty ? "Kaspa Contact" : trimmed
                )
            }

            return SystemContactLinkTarget(
                contactIdentifier: contactIdentifier,
                displayName: self.safeDisplayName(for: contactIdentifier)
            )
        }
    }

    func updateAutoCreatedContactName(contactIdentifier: String, newName: String) async throws {
        do {
            try await performStoreOperation { [self] in
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor
                ]
                let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
                let isAutoCreated = contact.urlAddresses.contains {
                    ($0.value as String).lowercased().hasPrefix(kaChatAutoMarkerPrefix)
                }
                guard isAutoCreated else { return }
                guard let mutable = contact.mutableCopy() as? CNMutableContact else { return }
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                mutable.givenName = trimmed.isEmpty ? "Kaspa Contact" : trimmed
                mutable.familyName = ""
                let request = CNSaveRequest()
                request.update(mutable)
                try store.execute(request)
            }
        } catch {
            if isMissingRecordError(error) {
                return
            }
            throw error
        }
    }

    func deleteAutoCreatedKaChatContact(contactIdentifier: String, appContactId: UUID) async throws -> Bool {
        do {
            return try await performStoreOperation { [self] in
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor
                ]
                let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
                let expectedMarker = kaChatAutoMarkerPrefix + appContactId.uuidString.lowercased()
                let hasExpectedMarker = contact.urlAddresses.contains {
                    (($0.value as String).lowercased() == expectedMarker)
                }
                guard hasExpectedMarker else {
                    return false
                }
                guard let mutable = contact.mutableCopy() as? CNMutableContact else { return false }
                let request = CNSaveRequest()
                request.delete(mutable)
                try store.execute(request)
                return true
            }
        } catch {
            if isMissingRecordError(error) {
                return false
            }
            throw error
        }
    }

    /// Removes KaChat-managed data (Kaspa address URLs, KNS IM entries, auto marker) from a system contact.
    /// Used when user explicitly unlinks, so the contact won't be re-matched on next refresh.
    func removeKaChatData(contactIdentifier: String) async throws {
        do {
            try await performStoreOperation { [self] in
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor,
                    CNContactInstantMessageAddressesKey as CNKeyDescriptor
                ]
                let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
                guard let mutable = contact.mutableCopy() as? CNMutableContact else { return }

                mutable.urlAddresses.removeAll { entry in
                    let value = (entry.value as String).lowercased()
                    return entry.label == kaspaURLLabel
                        || value.hasPrefix(kaChatAutoMarkerPrefix)
                        || (addressRegex?.firstMatch(
                                in: value, options: [],
                                range: NSRange(location: 0, length: (value as NSString).length)
                            ) != nil)
                }

                mutable.instantMessageAddresses.removeAll { entry in
                    entry.value.service.lowercased() == knsInstantMessageService.lowercased()
                }

                let request = CNSaveRequest()
                request.update(mutable)
                try store.execute(request)
            }
        } catch {
            if isMissingRecordError(error) {
                return
            }
            throw error
        }
    }

    /// Removes duplicate and orphaned auto-created KaChat contacts from the system contacts store.
    /// `activeLinks` maps currently-linked system contact identifiers to their Kaspa addresses.
    /// Any auto-created contact whose identifier is NOT in `activeLinks` is deleted.
    func removeOrphanedAutoCreatedContacts(activeLinks: [String: String]) async -> Int {
        do {
            return try await performStoreOperation { [self] in
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor
                ]
                let fetchRequest = CNContactFetchRequest(keysToFetch: keys)
                fetchRequest.unifyResults = false

                var toDelete: [CNMutableContact] = []
                try store.enumerateContacts(with: fetchRequest) { contact, _ in
                    guard contact.isKeyAvailable(CNContactIdentifierKey),
                          !contact.identifier.isEmpty else { return }

                    let hasAutoMarker = contact.urlAddresses.contains {
                        ($0.value as String).lowercased().hasPrefix(self.kaChatAutoMarkerPrefix)
                    }
                    guard hasAutoMarker else { return }

                    // This is an auto-created KaChat contact.
                    // Keep it only if it's actively linked.
                    if activeLinks[contact.identifier] != nil {
                        return
                    }

                    if let mutable = contact.mutableCopy() as? CNMutableContact {
                        toDelete.append(mutable)
                    }
                }

                guard !toDelete.isEmpty else { return 0 }

                let request = CNSaveRequest()
                for mutable in toDelete {
                    request.delete(mutable)
                }
                try store.execute(request)
                return toDelete.count
            }
        } catch {
            if !isMissingRecordError(error) {
                AppLog.log("[SystemContactsService] Failed to remove orphaned auto-created contacts: %@",
                      error.localizedDescription)
            }
            return 0
        }
    }

    private func preferredDisplayName(for contact: CNContact) -> String {
        // Avoid CNContactFormatter here. It can read keys we didn't request and throw
        // CNPropertyNotFetchedException on restricted profiles.
        let given = contact.isKeyAvailable(CNContactGivenNameKey)
            ? contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let middle = contact.isKeyAvailable(CNContactMiddleNameKey)
            ? contact.middleName.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let family = contact.isKeyAvailable(CNContactFamilyNameKey)
            ? contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let formatterName = [given, middle, family]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !formatterName.isEmpty {
            return formatterName
        }
        let nickname = contact.isKeyAvailable(CNContactNicknameKey)
            ? contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !nickname.isEmpty {
            return nickname
        }
        let org = contact.isKeyAvailable(CNContactOrganizationNameKey)
            ? contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !org.isEmpty {
            return org
        }
        return "System Contact"
    }

    private func safeDisplayName(for contactIdentifier: String) -> String {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]

        do {
            let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
            return preferredDisplayName(for: contact)
        } catch {
            return "System Contact"
        }
    }

    private func extractKaspaAddresses(from values: [String]) -> Set<String> {
        var results: Set<String> = []
        for value in values where !value.isEmpty {
            let lowered = value.lowercased()
            let nsValue = lowered as NSString
            guard let regex = addressRegex else { continue }
            let matches = regex.matches(in: lowered, options: [], range: NSRange(location: 0, length: nsValue.length))
            for match in matches where match.range.location != NSNotFound {
                let address = nsValue.substring(with: match.range)
                if KaspaAddress.isValid(address) {
                    results.insert(address)
                }
            }
        }
        return results
    }

    private func normalizeKnsDomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        if !value.hasSuffix(".kas") {
            value += ".kas"
        }
        return value
    }

    private func canonicalKaspaValue(from raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if KaspaAddress.isValid(value) {
            return value
        }
        return normalizeKnsDomain(value)
    }

}


// MARK: - System-contact avatar store

/// Photos from the iOS Contacts app for linked contacts, cached in memory + on disk.
///
/// Avatar resolution order, applied identically everywhere by `KNSAvatarView` (pass it
/// `contactAddress:` - never re-implement this per call site):
///   1. KNS avatar, when the contact has one
///   2. the linked Contacts-app photo
///   3. the person-glyph fallback
/// The per-contact Chat Info "Avatar" picker (`Contact.preferKNSAvatar`) is the explicit
/// override: `false` promotes the Contacts-app photo above the KNS avatar, `true`/nil keep
/// the default order above.
@MainActor
final class SystemContactAvatarStore: ObservableObject {
    static let shared = SystemContactAvatarStore()

    /// systemContactId -> thumbnail. An `NSCache` rather than a dictionary so the set of decoded
    /// thumbnails is bounded (a large address book used to pin every photo it ever showed for the
    /// life of the process) and so the system can shed them under pressure. Cost is pixel bytes,
    /// which is what the decoded bitmap actually occupies.
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// The change signal views observe. `NSCache` isn't observable, so every insert bumps this;
    /// a view that read `nil` during body evaluation re-runs and finds the image on the next pass.
    @Published private(set) var version = 0
    /// Ids already attempted this session (including photo-less contacts) - one CN fetch each.
    /// Bounded like `KNSService.lastAttemptAt`: past the cap the oldest attempts are forgotten,
    /// which at worst costs one extra disk read for a contact not seen in a long while.
    private var attemptedAt: [String: Date] = [:]
    private let maxAttemptEntries = 2_048

    private init() {
        // Nothing else in the app listens for memory warnings; the decoded thumbnails are the
        // one cache here that is pure convenience (disk copy + Contacts app both still have
        // the photo), so drop them first. The attempt set goes too, or a cleared image would
        // read as "already tried, no photo" and never come back.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeMemoryCache()
            }
        }
    }

    private func purgeMemoryCache() {
        images.removeAllObjects()
        attemptedAt.removeAll()
        version &+= 1
    }

    private lazy var diskDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("ContactAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-derivable from the Contacts app (CacheManager already classes this directory as
        // cache), so it has no business in an iCloud/iTunes backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private func diskURL(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return diskDirectory.appendingPathComponent(safe + ".jpg")
    }

    private static func cacheCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let scale = max(1, image.scale)
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    private func setImage(_ image: UIImage, for id: String) {
        images.setObject(image, forKey: id as NSString, cost: Self.cacheCost(for: image))
        version &+= 1
    }

    private func markAttempted(_ id: String) {
        attemptedAt[id] = Date()
        guard attemptedAt.count > maxAttemptEntries else { return }
        let overflow = attemptedAt.count - maxAttemptEntries
        let oldestKeys = attemptedAt.sorted { $0.value < $1.value }.prefix(overflow).map(\.key)
        for key in oldestKeys {
            attemptedAt.removeValue(forKey: key)
        }
    }

    /// Drops every trace of a system contact's photo (memory, attempt record, and the JPEG on
    /// disk). Called when the app contact is unlinked or deleted - the file would otherwise sit
    /// in Application Support forever, since nothing else ever prunes that directory.
    func removeCachedPhoto(forSystemContactId id: String?) {
        guard let id else { return }
        images.removeObject(forKey: id as NSString)
        attemptedAt.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: diskURL(for: id))
        version &+= 1
    }

    /// The Contacts-app photo regardless of the user's per-contact choice (Chat Info picker
    /// availability check + preview). Triggers a lazy fetch on first ask; views observing the
    /// store re-render when it lands.
    func rawImage(for contact: Contact?) -> UIImage? {
        guard let id = contact?.systemContactId else { return nil }
        if let image = images.object(forKey: id as NSString) { return image }
        fetchIfNeeded(id: id)
        return nil
    }

    /// Address-keyed variant used by `KNSAvatarView` so any avatar in the app can fall back to
    /// the device-contact photo just by naming the address it represents. Returns nil when the
    /// address isn't in the address book, isn't linked to a system contact, or has no photo.
    func photo(forAddress address: String?) -> UIImage? {
        guard let contact = contact(forAddress: address) else { return nil }
        return rawImage(for: contact)
    }

    /// True only when the user explicitly picked "Contacts Photo" for this contact in Chat Info;
    /// that's the one case where the device photo outranks a KNS avatar.
    func prefersContactPhotoOverKNS(forAddress address: String?) -> Bool {
        contact(forAddress: address)?.preferKNSAvatar == false
    }

    private func contact(forAddress address: String?) -> Contact? {
        guard let address, !address.isEmpty else { return nil }
        return ContactsManager.shared.getContact(byAddress: address)
    }

    /// Overwrites the cached photo (memory + disk) - used after writing a new photo into the
    /// system contact so the in-app avatar updates immediately.
    func storeImage(_ image: UIImage, data: Data, forSystemContactId id: String) {
        setImage(image, for: id)
        markAttempted(id)
        try? data.write(to: diskURL(for: id))
    }

    /// Warms the cache for every linked contact once, right after a system-contacts bootstrap,
    /// so chat lists render photos on first paint instead of popping them in row by row. Each id
    /// still costs at most one CN fetch (`attemptedIds`), and each fetch is off the main thread.
    func prefetchPhotos(for contacts: [Contact]) {
        for id in Set(contacts.compactMap(\.systemContactId)) {
            fetchIfNeeded(id: id)
        }
    }

    private func fetchIfNeeded(id: String) {
        guard attemptedAt[id] == nil else { return }
        markAttempted(id)

        // Everything - including the disk-cache hit - publishes from a detached task, never
        // synchronously: views ask for avatars during body evaluation, and a synchronous
        // `version` write there is SwiftUI's "publishing changes from within view updates".
        let targetURL = diskURL(for: id)
        let status = CNContactStore.authorizationStatus(for: .contacts)
        Task.detached(priority: .utility) {
            if let data = try? Data(contentsOf: targetURL), let image = UIImage(data: data) {
                await MainActor.run {
                    SystemContactAvatarStore.shared.setImage(image, for: id)
                }
                return
            }
            guard status == .authorized else { return }
            let store = CNContactStore()
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            guard let cnContact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys),
                  let data = cnContact.thumbnailImageData,
                  let image = UIImage(data: data) else { return }
            try? data.write(to: targetURL)
            await MainActor.run {
                SystemContactAvatarStore.shared.setImage(image, for: id)
            }
        }
    }
}
