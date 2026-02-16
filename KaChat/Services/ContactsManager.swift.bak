import Foundation
import Contacts

@MainActor
final class ContactsManager: ObservableObject {
    static let shared = ContactsManager()

    @Published var contacts: [Contact] = []
    @Published var isLoading = false
    @Published var error: KasiaError?
    @Published var isFetchingKNS = false
    @Published private(set) var contactBalances: [String: UInt64] = [:]
    @Published private(set) var systemContactsAuthorized = false
    @Published private(set) var systemContactCandidates: [SystemContactCandidate] = []

    private let userDefaults = UserDefaults.standard
    private let legacyContactsKey = "kachat_contacts"
    private let contactsKeyPrefix = "kachat_contacts_wallet_"
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
    private var autoCreateSystemContactsEnabled = AppSettings.load().autoCreateSystemContacts
    private var didBootstrapSystemContacts = false
    private var settingsObserver: NSObjectProtocol?

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
        contacts.filter { !$0.isArchived }
    }

    var archivedContacts: [Contact] {
        contacts.filter { $0.isArchived }
    }

    // MARK: - KNS Integration

    /// Fetch KNS domains for all contacts
    func fetchKNSDomainsForAllContacts(network: NetworkType = .mainnet) async {
        guard !contacts.isEmpty else { return }

        isFetchingKNS = true
        defer { isFetchingKNS = false }

        let addresses = contacts.map { $0.address }
        await knsService.refreshIfNeeded(for: addresses, network: network)

        // Update aliases for contacts that have auto-generated names or stale .kas names
        for contact in contacts {
            if let knsInfo = knsService.domainCache[contact.address],
               let primaryDomain = knsInfo.primaryDomain {
                // Check if alias is auto-generated (matches last 8 chars of address)
                let autoAlias = Contact.generateDefaultAlias(from: contact.address)
                if contact.alias == autoAlias || contact.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Update to KNS domain name
                    var updatedContact = contact
                    updatedContact.alias = primaryDomain
                    updateContact(updatedContact)
                } else if contact.alias.lowercased().hasSuffix(".kas") && contact.alias != primaryDomain {
                    // Keep KNS domain fresh when alias is domain-based
                    var updatedContact = contact
                    updatedContact.alias = primaryDomain
                    updateContact(updatedContact)
                }
            }
        }

        // Also repair linked system contact URL entries immediately using normalized KNS domains.
        // This fixes legacy values like "http://name.kas" without waiting for periodic refresh.
        for contact in contacts {
            guard let linkedId = contact.systemContactId else { continue }
            guard let info = knsService.domainCache[contact.address] else { continue }
            let domains = info.allDomains.map { $0.fullName }
            do {
                try await systemContactsService.upsertKaChatData(
                    contactIdentifier: linkedId,
                    address: contact.address,
                    domains: domains,
                    appContactId: contact.id,
                    autoCreated: contact.systemContactLinkSource == .autoCreated
                )
            } catch {
                // Best effort only.
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

    /// Fetch KNS info for a specific contact
    func fetchKNSInfo(for contact: Contact, network: NetworkType = .mainnet) async -> KNSAddressInfo? {
        await knsService.refreshIfNeeded(for: [contact.address], network: network)
        return knsService.domainCache[contact.address]
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

        if activeWalletAddress == normalizedAddress {
            clearInMemoryContacts(syncShared: true, updatePush: false)
        }
    }

    func loadContacts() {
        guard let contactsKey = activeContactsKey else {
            contacts = []
            return
        }

        if let scopedData = userDefaults.data(forKey: contactsKey),
           let decodedContacts = try? JSONDecoder().decode([Contact].self, from: scopedData) {
            contacts = sortContacts(decodedContacts)
            return
        }

        // One-time migration from legacy single-account key to active wallet-scoped key.
        if let legacyData = userDefaults.data(forKey: legacyContactsKey),
           let decodedLegacy = try? JSONDecoder().decode([Contact].self, from: legacyData) {
            contacts = sortContacts(decodedLegacy)
            if let migratedData = try? JSONEncoder().encode(decodedLegacy) {
                userDefaults.set(migratedData, forKey: contactsKey)
                userDefaults.removeObject(forKey: legacyContactsKey)
            }
            return
        }

        contacts = []
    }

    func addContact(address: String, alias: String = "", isAutoAdded: Bool = false) throws -> Contact {
        // Validate address format
        guard isValidKaspaAddress(address) else {
            throw KasiaError.invalidAddress
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

    func deleteContact(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        saveContacts()
    }

    func deleteContact(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
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
        return contacts.first { $0.address == address }
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
                // If alias is auto-generated, update to KNS domain
                let autoAlias = Contact.generateDefaultAlias(from: address)
                if let index = contacts.firstIndex(where: { $0.address == address }),
                   contacts[index].alias == autoAlias {
                    contacts[index].alias = primaryDomain
                    saveContacts(publishContacts: true)
                }
            }
        }

        return contact
    }

    func searchContacts(_ query: String, includeArchived: Bool = false) -> [Contact] {
        let source = includeArchived ? contacts : activeContacts
        guard !query.isEmpty else { return source }

        let lowercasedQuery = query.lowercased()
        return source.filter {
            $0.alias.lowercased().contains(lowercasedQuery) ||
            $0.address.lowercased().contains(lowercasedQuery)
        }
    }

    func setContactArchived(address: String, isArchived: Bool) {
        guard let index = contacts.firstIndex(where: { $0.address == address }) else { return }
        guard contacts[index].isArchived != isArchived else { return }
        contacts[index].isArchived = isArchived
        saveContacts(publishContacts: true)
        // Sync to Core Data / CloudKit for multi-device
        MessageStore.shared.setConversationArchived(contactAddress: address, isArchived: isArchived)
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
            NSLog("[ContactsManager] Failed to load system contact link targets: %@", error.localizedDescription)
            return []
        }
    }

    func refreshSystemContactLinks(promptIfNeeded: Bool = false, force: Bool = false) async {
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
        guard !candidates.isEmpty else { return }

        var contactsByAddress: [String: SystemContactCandidate] = [:]
        for candidate in candidates {
            contactsByAddress[candidate.address.lowercased()] = candidate
        }

        var updated = false
        let contactIds = contacts.map(\.id)
        for contactId in contactIds {
            guard let index = contacts.firstIndex(where: { $0.id == contactId }) else { continue }
            let current = contacts[index]
            let addressKey = current.address.lowercased()
            if let candidate = contactsByAddress[addressKey] {
                if current.systemContactId != candidate.contactIdentifier ||
                    current.systemDisplayNameSnapshot != candidate.displayName ||
                    current.systemMatchConfidence != 1.0 {
                    contacts[index].systemContactId = candidate.contactIdentifier
                    contacts[index].systemDisplayNameSnapshot = candidate.displayName
                    if !(current.systemContactLinkSource == .manual && current.systemContactId == candidate.contactIdentifier) {
                        contacts[index].systemContactLinkSource = .matched
                    }
                    contacts[index].systemMatchConfidence = 1.0
                    contacts[index].systemLastSyncedAt = now
                    updated = true
                }

                let autoAlias = Contact.generateDefaultAlias(from: current.address)
                let trimmedAlias = current.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedAlias.isEmpty || trimmedAlias == autoAlias {
                    if contacts[index].alias != candidate.displayName {
                        contacts[index].alias = candidate.displayName
                        updated = true
                    }
                }
            } else if autoCreateSystemContactsEnabled && current.systemContactId == nil {
                // No existing link and no non-duplicate match in system contacts:
                // auto-create a dedicated system contact and link to it.
                let domains = await fetchKNSInfo(for: current)?.allDomains.map { $0.fullName } ?? []
                do {
                    let created = try await systemContactsService.createKaChatContact(
                        displayName: current.alias,
                        address: current.address,
                        domains: domains,
                        appContactId: current.id
                    )
                    if !created.contactIdentifier.isEmpty,
                       let writeIndex = contacts.firstIndex(where: { $0.id == contactId }),
                       contacts[writeIndex].systemContactId == nil {
                        contacts[writeIndex].systemContactId = created.contactIdentifier
                        contacts[writeIndex].systemDisplayNameSnapshot = created.displayName
                        contacts[writeIndex].systemContactLinkSource = .autoCreated
                        contacts[writeIndex].systemMatchConfidence = 1.0
                        contacts[writeIndex].systemLastSyncedAt = now
                        updated = true
                    }
                } catch {
                    // Best effort only.
                }
            }

            // Keep linked system contact metadata canonicalized and up to date.
            // This also repairs legacy URL entries like "http://name" -> "name.kas".
            guard let latestIndex = contacts.firstIndex(where: { $0.id == contactId }) else { continue }
            let latest = contacts[latestIndex]
            if let linkedId = latest.systemContactId {
                let domains = getKNSInfo(for: latest)?.allDomains.map { $0.fullName } ?? []
                do {
                    try await systemContactsService.upsertKaChatData(
                        contactIdentifier: linkedId,
                        address: latest.address,
                        domains: domains,
                        appContactId: latest.id,
                        autoCreated: latest.systemContactLinkSource == .autoCreated
                    )
                } catch {
                    // Best effort only.
                }
            }
        }

        lastSystemContactsRefreshAt = now
        if updated {
            saveContacts(syncShared: true, updatePush: false, publishContacts: true)
        }
    }

    func linkContact(_ contact: Contact, to candidate: SystemContactCandidate, updateAlias: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        let current = contacts[index]
        let autoAlias = Contact.generateDefaultAlias(from: current.address)
        let trimmedAlias = current.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldAdoptSystemName = updateAlias || trimmedAlias.isEmpty || trimmedAlias == autoAlias
        let previousId = contacts[index].systemContactId
        let previousSource = contacts[index].systemContactLinkSource
        contacts[index].systemContactId = candidate.contactIdentifier
        contacts[index].systemDisplayNameSnapshot = candidate.displayName
        contacts[index].systemContactLinkSource = .manual
        contacts[index].systemMatchConfidence = 1.0
        contacts[index].systemLastSyncedAt = Date()
        if shouldAdoptSystemName {
            contacts[index].alias = candidate.displayName
        }
        saveContacts(syncShared: true, updatePush: false, publishContacts: true)

        // If user relinked from an auto-created record, remove that duplicate safely.
        if previousSource == .autoCreated,
           let previousId,
           previousId != candidate.contactIdentifier {
            Task {
                _ = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                    contactIdentifier: previousId,
                    appContactId: contact.id
                )
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
        let shouldAdoptSystemName = updateAlias || trimmedAlias.isEmpty || trimmedAlias == autoAlias
        let previousId = contacts[index].systemContactId
        let previousSource = contacts[index].systemContactLinkSource
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
            try await runWithTimeout(
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
        } catch {
            NSLog("[ContactsManager] Failed to write KaChat metadata to system contact %@: %@",
                  target.contactIdentifier, error.localizedDescription)
        }

        // If user relinked from an auto-created record, remove that duplicate safely.
        if previousSource == .autoCreated,
           let previousId,
           previousId != target.contactIdentifier {
            _ = try? await systemContactsService.deleteAutoCreatedKaChatContact(
                contactIdentifier: previousId,
                appContactId: contact.id
            )
        }
    }

    func unlinkSystemContact(_ contact: Contact) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[index].systemContactId = nil
        contacts[index].systemDisplayNameSnapshot = nil
        contacts[index].systemContactLinkSource = nil
        contacts[index].systemMatchConfidence = nil
        contacts[index].systemLastSyncedAt = Date()
        saveContacts(syncShared: true, updatePush: false, publishContacts: true)
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
                self?.applySystemContactsSetting(
                    syncEnabled: settings.syncSystemContacts,
                    autoCreateEnabled: settings.autoCreateSystemContacts
                )
            }
        }
    }

    private func applySystemContactsSetting(syncEnabled: Bool, autoCreateEnabled: Bool) {
        syncSystemContactsEnabled = syncEnabled
        autoCreateSystemContactsEnabled = autoCreateEnabled
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
        qos: .userInitiated
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
                CNContactOrganizationNameKey as CNKeyDescriptor
            ]

            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = false

            var targets: [SystemContactLinkTarget] = []
            try store.enumerateContacts(with: request) { [self] contact, _ in
                guard contact.isKeyAvailable(CNContactIdentifierKey) else { return }
                let contactIdentifier = contact.identifier
                guard !contactIdentifier.isEmpty else { return }

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
            let extracted = self.extractKaspaAddresses(from: addressSources)
            for address in extracted {
                let candidate = SystemContactCandidate(
                    contactIdentifier: contactIdentifier,
                    displayName: displayName,
                    address: address,
                    sourceHint: nil
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
    ) async throws {
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

    func deleteAutoCreatedKaChatContact(contactIdentifier: String, appContactId: UUID) async throws -> Bool {
        try await performStoreOperation { [self] in
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
