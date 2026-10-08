import Foundation

/// A deleted Address Book entry, kept so a backup merge from another device never brings it back.
struct AddressBookTombstone: Codable, Equatable, Hashable {
    var address: String
    var deletedAt: Date
}

/// The Address Book (Kaspa Hub > Address Book): saved Kaspa addresses with a name and a note.
///
/// It replaces syncing with the phone's Contacts (removed 2026-10-08). That linked Kaspa addresses
/// to phone numbers in people's address books, which sync to iCloud/Google and which any app with
/// Contacts access can read. The Address Book lives only in KaChat:
/// - one per wallet, like chats and contacts, so switching wallets never shows who another wallet
///   knows;
/// - on this device (UserDefaults) and in the wallet's chat backup (`addressBook` +
///   `addressBookDeleted` in the archive), so a restore or another device brings it back.
///
/// A saved name is also how KaChat shows that address when you haven't named the chat contact
/// yourself (`ContactsManager.displayName`).
@MainActor
final class AddressBookManager: ObservableObject {
    static let shared = AddressBookManager()

    /// Sorted by name.
    @Published private(set) var entries: [AddressBookEntry] = []
    /// Normalized address -> when it was deleted.
    private var deleted: [String: Date] = [:]
    private var byAddress: [String: Int] = [:]
    private var walletAddress: String?
    private let defaults = UserDefaults.standard

    private static let entriesKeyPrefix = "kachat_address_book_wallet_"
    private static let deletedKeyPrefix = "kachat_address_book_deleted_wallet_"
    private static let migratedKeyPrefix = "kachat_address_book_migrated_v1_wallet_"

    private init() {}

    // MARK: - Wallet

    /// Loads the book of `walletAddress` (nil: no wallet, an empty book). Called by
    /// `ContactsManager.setActiveWalletAddress` right after it has loaded that wallet's contacts,
    /// so the one-time migration below sees them.
    func setActiveWalletAddress(_ walletAddress: String?) {
        let wallet = walletAddress.map(Self.normalize)
        self.walletAddress = wallet
        guard let wallet, !wallet.isEmpty else {
            entries = []
            deleted = [:]
            rebuildIndex()
            return
        }
        let stored = defaults.data(forKey: Self.entriesKeyPrefix + wallet)
            .flatMap { try? JSONDecoder().decode([AddressBookEntry].self, from: $0) } ?? []
        let tombstones = defaults.data(forKey: Self.deletedKeyPrefix + wallet)
            .flatMap { try? JSONDecoder().decode([AddressBookTombstone].self, from: $0) } ?? []
        deleted = Dictionary(tombstones.map { (Self.normalize($0.address), $0.deletedAt) }, uniquingKeysWith: max)
        entries = Self.sorted(stored)
        rebuildIndex()
        migrateLinkedNames(from: ContactsManager.shared.contacts)
    }

    /// Once per wallet: every chat contact that was linked to a phone contact becomes an Address
    /// Book entry with that phone contact's name and the Kaspa address only (no phone number, no
    /// link).
    private func migrateLinkedNames(from contacts: [Contact]) {
        guard let walletAddress else { return }
        let flag = Self.migratedKeyPrefix + walletAddress
        guard !defaults.bool(forKey: flag) else { return }
        var added = false
        for contact in contacts {
            guard let name = contact.legacyLinkedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, entry(for: contact.address) == nil else { continue }
            entries.append(AddressBookEntry(address: Self.normalize(contact.address), name: name))
            added = true
        }
        defaults.set(true, forKey: flag)
        if added {
            entries = Self.sorted(entries)
            rebuildIndex()
            persist()
            AppLog.log("[AddressBook] moved linked phone-contact names into the Address Book")
        }
    }

    // MARK: - Reading

    func entry(for address: String?) -> AddressBookEntry? {
        guard let address, !address.isEmpty, let i = byAddress[Self.normalize(address)] else { return nil }
        return entries[i]
    }

    func search(_ query: String) -> [AddressBookEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q) || $0.note.lowercased().contains(q)
        }
    }

    // MARK: - Writing

    enum SaveError: LocalizedError {
        case noWallet, emptyName, invalidAddress

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("Open a wallet first.")
            case .emptyName: return AppLocalization.string("Enter a name.")
            case .invalidAddress: return AppLocalization.string("Enter a valid Kaspa address.")
            }
        }
    }

    /// Adds `address`, or updates its entry when it is already saved.
    @discardableResult
    func save(address: String, name: String, note: String = "") throws -> AddressBookEntry {
        guard walletAddress != nil else { throw SaveError.noWallet }
        let address = Self.normalize(address)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SaveError.emptyName }
        guard ContactsManager.shared.isValidKaspaAddress(address) else { throw SaveError.invalidAddress }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: AddressBookEntry
        if let i = byAddress[address] {
            entries[i].name = name
            entries[i].note = note
            entries[i].updatedAt = Date()
            saved = entries[i]
        } else {
            saved = AddressBookEntry(address: address, name: name, note: note)
            entries.append(saved)
        }
        deleted[address] = nil
        entries = Self.sorted(entries)
        rebuildIndex()
        persist()
        didChange()
        return saved
    }

    func remove(address: String) {
        let address = Self.normalize(address)
        guard let i = byAddress[address] else { return }
        entries.remove(at: i)
        deleted[address] = Date()
        rebuildIndex()
        persist()
        didChange()
    }

    // MARK: - Backup

    /// What the chat backup carries for this wallet.
    var archiveEntries: [AddressBookEntry] { entries }
    var archiveTombstones: [AddressBookTombstone] {
        deleted.map { AddressBookTombstone(address: $0.key, deletedAt: $0.value) }.sorted { $0.address < $1.address }
    }

    /// A restore: per address the newest event wins - an entry edited after it was deleted
    /// elsewhere comes back, one deleted after its last edit stays deleted.
    func importFromArchive(entries incoming: [AddressBookEntry], tombstones: [AddressBookTombstone]) {
        guard walletAddress != nil, !(incoming.isEmpty && tombstones.isEmpty) else { return }
        let merged = Self.merge(
            entries: [entries, incoming], tombstones: [archiveTombstones, tombstones]
        )
        entries = Self.sorted(merged.entries)
        deleted = Dictionary(merged.tombstones.map { ($0.address, $0.deletedAt) }, uniquingKeysWith: max)
        rebuildIndex()
        persist()
        SharedDataManager.syncContactsForExtension()
    }

    /// The merge both restore and the shared-backup upload use (`ChatService.mergeBackupArchives`).
    nonisolated static func merge(
        entries sides: [[AddressBookEntry]], tombstones tombSides: [[AddressBookTombstone]]
    ) -> (entries: [AddressBookEntry], tombstones: [AddressBookTombstone]) {
        var latest: [String: AddressBookEntry] = [:]
        for entry in sides.joined() {
            var e = entry
            e.address = normalize(e.address)
            if let have = latest[e.address], have.updatedAt >= e.updatedAt { continue }
            latest[e.address] = e
        }
        var deletedAt: [String: Date] = [:]
        for t in tombSides.joined() {
            let a = normalize(t.address)
            deletedAt[a] = max(deletedAt[a] ?? .distantPast, t.deletedAt)
        }
        var kept: [AddressBookEntry] = []
        for (address, e) in latest {
            if let d = deletedAt[address], d >= e.updatedAt { continue }
            kept.append(e)
            deletedAt[address] = nil
        }
        let tombs = deletedAt.map { AddressBookTombstone(address: $0.key, deletedAt: $0.value) }.sorted { $0.address < $1.address }
        return (sorted(kept), tombs)
    }

    // MARK: - Helpers

    /// Kaspa addresses are lowercase; a pasted or scanned one may carry spaces or a `?amount=` query.
    nonisolated static func normalize(_ address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let q = a.firstIndex(of: "?") { a = String(a[..<q]) }
        return a
    }

    nonisolated private static func sorted(_ list: [AddressBookEntry]) -> [AddressBookEntry] {
        list.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.address < $1.address : order == .orderedAscending
        }
    }

    private func rebuildIndex() {
        byAddress = Dictionary(entries.enumerated().map { (Self.normalize($0.element.address), $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    /// A user edit: names in notifications and the share sheet follow, and the backup owes an upload.
    private func didChange() {
        SharedDataManager.syncContactsForExtension()
        NextcloudService.shared.noteMessageActivity()
    }

    private func persist() {
        guard let walletAddress else { return }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKeyPrefix + walletAddress)
        }
        if let data = try? JSONEncoder().encode(archiveTombstones) {
            defaults.set(data, forKey: Self.deletedKeyPrefix + walletAddress)
        }
    }
}
