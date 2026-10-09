import CryptoKit
import Foundation
import UIKit

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
///
/// An entry's picture is either a photo you assign to it, or else exactly the avatar that address
/// set on its own profile (`AddressBookAvatar`). Assigned photos are your data, not cache: they live
/// in Application Support/AddressBookPhotos/<wallet>/ (never purged by the system), travel in the
/// backup as `photo`, and Settings > Storage shows the space they take and can remove them.
@MainActor
final class AddressBookManager: ObservableObject {
    static let shared = AddressBookManager()

    /// Sorted by name.
    @Published private(set) var entries: [AddressBookEntry] = []
    /// Bumped whenever an assigned photo changes, so pictures re-read it.
    @Published private(set) var photoVersion = 0
    /// Normalized address -> when it was deleted.
    private var deleted: [String: Date] = [:]
    private var byAddress: [String: Int] = [:]
    private var walletAddress: String?
    private let defaults = UserDefaults.standard

    private static let entriesKeyPrefix = "kachat_address_book_wallet_"
    private static let deletedKeyPrefix = "kachat_address_book_deleted_wallet_"
    private static let migratedKeyPrefix = "kachat_address_book_migrated_v1_wallet_"

    private let photoCache = NSCache<NSString, UIImage>()

    private init() {
        photoCache.countLimit = 200
    }

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
        photoCache.removeAllObjects()
        photoVersion &+= 1
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
        /// A valid address of the network the app isn't on (`KaspaAddress.otherNetworkReason`).
        case otherNetwork(String)

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("Open a wallet first.")
            case .emptyName: return AppLocalization.string("Enter a name.")
            case .invalidAddress: return AppLocalization.string("Enter a valid Kaspa address.")
            case .otherNetwork(let reason): return reason
            }
        }
    }

    /// What a save does to the entry's assigned photo.
    enum PhotoChange: Equatable {
        case unchanged
        /// JPEG data, already scaled down (`preparedPhoto(from:)`)
        case set(Data)
        case removed
    }

    /// Adds `address`, or updates its entry when it is already saved.
    @discardableResult
    func save(address: String, name: String, note: String = "", photo: PhotoChange = .unchanged) throws -> AddressBookEntry {
        guard walletAddress != nil else { throw SaveError.noWallet }
        let address = Self.normalize(address)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SaveError.emptyName }
        // the network the app runs on only: the other network's address is the same key on the
        // other chain, a chat with it is never read and is dropped on the next launch (IOS-063)
        if let reason = KaspaAddress.otherNetworkReason(address) { throw SaveError.otherNetwork(reason) }
        guard KaspaAddress.isValidOnActiveNetwork(address) else { throw SaveError.invalidAddress }
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
        switch photo {
        case .unchanged: break
        case .set(let data): writePhoto(data, for: address)
        case .removed: deletePhoto(for: address)
        }
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
        deletePhoto(for: address)
        rebuildIndex()
        persist()
        didChange()
    }

    // MARK: - Assigned photos

    /// The photo you assigned to `address`, if any.
    func photo(for address: String?) -> UIImage? {
        guard let address, let url = photoURL(for: Self.normalize(address)) else { return nil }
        let key = url.path as NSString
        if let cached = photoCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        photoCache.setObject(image, forKey: key)
        return image
    }

    func hasPhoto(for address: String?) -> Bool {
        guard let address, let url = photoURL(for: Self.normalize(address)) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A picked image as the JPEG an entry keeps: at most 384 px on its longer side (an avatar is
    /// never drawn bigger), quality 0.8 - tens of KB, so the backup stays small.
    nonisolated static func preparedPhoto(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 384
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }

    /// Space the assigned photos of every wallet on this device take (Settings > Storage).
    nonisolated static func photosBytesOnDevice() -> Int64 {
        guard let root = photosRoot,
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Settings > Storage > Remove: deletes the assigned photos of every wallet on this device.
    /// Each affected entry counts as edited, so the removal also reaches the backup instead of the
    /// photo coming back from it.
    func removeAllPhotos() {
        let now = Date()
        let wallets = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.entriesKeyPrefix) }
            .map { String($0.dropFirst(Self.entriesKeyPrefix.count)) }
        for wallet in wallets {
            if wallet == walletAddress {
                for i in entries.indices where hasPhoto(for: entries[i].address) {
                    entries[i].updatedAt = now
                }
                persist()
                continue
            }
            let key = Self.entriesKeyPrefix + wallet
            guard var stored = defaults.data(forKey: key)
                .flatMap({ try? JSONDecoder().decode([AddressBookEntry].self, from: $0) }) else { continue }
            let dir = Self.photosDirectory(wallet: wallet)
            for i in stored.indices {
                if let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.photoFileName(stored[i].address)).path) {
                    stored[i].updatedAt = now
                }
            }
            if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
        }
        if let root = Self.photosRoot { try? FileManager.default.removeItem(at: root) }
        photoCache.removeAllObjects()
        photoVersion &+= 1
        if walletAddress != nil { NextcloudService.shared.noteMessageActivity() }
    }

    private nonisolated static var photosRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AddressBookPhotos", isDirectory: true)
    }

    /// One folder per wallet, named by a hash of its address (no address in a file path).
    private nonisolated static func photosDirectory(wallet: String) -> URL? {
        photosRoot?.appendingPathComponent(hashName(wallet), isDirectory: true)
    }

    private nonisolated static func photoFileName(_ address: String) -> String {
        hashName(normalize(address)) + ".jpg"
    }

    private nonisolated static func hashName(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func photoURL(for normalizedAddress: String) -> URL? {
        guard let walletAddress else { return nil }
        return Self.photosDirectory(wallet: walletAddress)?.appendingPathComponent(Self.photoFileName(normalizedAddress))
    }

    private func writePhoto(_ data: Data, for normalizedAddress: String) {
        guard let url = photoURL(for: normalizedAddress) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        photoCache.removeObject(forKey: url.path as NSString)
        photoVersion &+= 1
    }

    private func deletePhoto(for normalizedAddress: String) {
        guard let url = photoURL(for: normalizedAddress), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        photoCache.removeObject(forKey: url.path as NSString)
        photoVersion &+= 1
    }

    // MARK: - Export / import (Address Book > import-export sheet)

    /// The exported file: plain JSON, readable by any KaChat (iOS, Android, Desktop) and any wallet.
    struct ExportFile: Codable {
        static let kind = "kachat-address-book"
        var type: String = ExportFile.kind
        var version: Int = 1
        var exportedAt: Date
        /// The wallet it was exported from (informational: any wallet may import it).
        var walletAddress: String?
        /// Every entry with its assigned photo (base64 JPEG) attached.
        var entries: [AddressBookEntry]
    }

    enum ImportError: LocalizedError {
        case notAnAddressBook, empty
        /// Every address in the file is the other network's.
        case otherNetwork

        var errorDescription: String? {
            switch self {
            case .notAnAddressBook: return AppLocalization.string("That file isn't a KaChat Address Book export.")
            case .empty: return AppLocalization.string("That Address Book export has no addresses.")
            case .otherNetwork: return AppLocalization.string(AppSettings.load().networkType == .testnet
                ? "Every address in that file is a Mainnet address. KaChat is on Testnet."
                : "Every address in that file is a Testnet address. KaChat is on Mainnet.")
            }
        }
    }

    /// This wallet's Address Book as an export file.
    func exportData() throws -> Data {
        let file = ExportFile(exportedAt: Date(), walletAddress: walletAddress, entries: archiveEntries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// The export's file name, with the time so several exports don't overwrite each other.
    nonisolated static func exportFileName(at date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "KaChat Address Book \(stamp).json"
    }

    /// Imports an export file into this wallet's book: an address not saved here is added (even
    /// one deleted since - importing is asking for it back); one already saved takes the file's
    /// version only when that is newer. Photos come with their entry. Addresses of the other
    /// network are skipped (IOS-063). Returns (added, updated, skipped).
    @discardableResult
    func importExport(_ data: Data) throws -> (added: Int, updated: Int, skipped: Int) {
        guard walletAddress != nil else { throw SaveError.noWallet }
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        guard let file = (try? iso.decode(ExportFile.self, from: data)) ?? (try? JSONDecoder().decode(ExportFile.self, from: data)),
              file.type == ExportFile.kind else { throw ImportError.notAnAddressBook }
        let named = file.entries.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ContactsManager.shared.isValidKaspaAddress(Self.normalize($0.address))
        }
        let valid = named.filter { KaspaAddress.isValidOnActiveNetwork(Self.normalize($0.address)) }
        let skipped = named.count - valid.count
        guard !named.isEmpty else { throw ImportError.empty }
        guard !valid.isEmpty else { throw ImportError.otherNetwork }
        var added = 0, updated = 0
        for var incoming in valid {
            let address = Self.normalize(incoming.address)
            incoming.address = address
            let photo = incoming.photo.flatMap { Data(base64Encoded: $0) }
            incoming.photo = nil
            if let i = byAddress[address] {
                guard incoming.updatedAt > entries[i].updatedAt else { continue }
                entries[i].name = incoming.name
                entries[i].note = incoming.note
                entries[i].updatedAt = incoming.updatedAt
                if let photo { writePhoto(photo, for: address) } else { deletePhoto(for: address) }
                updated += 1
            } else {
                if entries.contains(where: { $0.id == incoming.id }) { incoming.id = UUID() }
                entries.append(incoming)
                if let photo { writePhoto(photo, for: address) }
                added += 1
                rebuildIndex()
            }
            deleted[address] = nil
        }
        entries = Self.sorted(entries)
        rebuildIndex()
        persist()
        if added + updated > 0 { didChange() }
        return (added, updated, skipped)
    }

    // MARK: - Backup

    /// What the chat backup carries for this wallet: each entry with its assigned photo (base64
    /// JPEG) attached.
    var archiveEntries: [AddressBookEntry] {
        entries.map { entry in
            var e = entry
            if let url = photoURL(for: Self.normalize(entry.address)), let data = try? Data(contentsOf: url) {
                e.photo = data.base64EncodedString()
            }
            return e
        }
    }
    var archiveTombstones: [AddressBookTombstone] {
        deleted.map { AddressBookTombstone(address: $0.key, deletedAt: $0.value) }.sorted { $0.address < $1.address }
    }

    /// A restore: per address the newest event wins - an entry edited after it was deleted
    /// elsewhere comes back, one deleted after its last edit stays deleted.
    func importFromArchive(entries incoming: [AddressBookEntry], tombstones: [AddressBookTombstone]) {
        guard walletAddress != nil, !(incoming.isEmpty && tombstones.isEmpty) else { return }
        let before = Dictionary(entries.map { (Self.normalize($0.address), $0) }, uniquingKeysWith: { a, _ in a })
        let merged = Self.merge(
            entries: [entries, incoming], tombstones: [archiveTombstones, tombstones]
        )
        // The winning entry decides the photo: one that came with a photo writes it; an incoming
        // winner without one removes ours (it was removed where that edit was made).
        var kept: [AddressBookEntry] = []
        for var e in merged.entries {
            let address = Self.normalize(e.address)
            if let base64 = e.photo, let data = Data(base64Encoded: base64) {
                writePhoto(data, for: address)
            } else if let local = before[address], local.updatedAt < e.updatedAt {
                deletePhoto(for: address)
            } else if before[address] == nil {
                deletePhoto(for: address)
            }
            e.photo = nil
            kept.append(e)
        }
        for t in merged.tombstones { deletePhoto(for: Self.normalize(t.address)) }
        entries = Self.sorted(kept)
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
