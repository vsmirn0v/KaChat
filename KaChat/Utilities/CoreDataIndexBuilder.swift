import Foundation
import CoreData
import SQLite3

/// Creates SQLite indexes directly on a Core Data store file, before the store is opened.
///
/// Core Data models can declare `NSFetchIndexDescription`s, but its version hash does NOT cover
/// them: an EXISTING store is judged compatible and keeps running without the new indexes, so
/// exactly the users with the most history - the ones who need them - get nothing. Forcing the
/// point with a `versionHashModifier` was tried and reverted: that runs a full lightweight
/// migration, which rewrites every row on the main thread. It wedged the app.
///
/// This does the one thing actually wanted instead. A SQLite index is invisible to Core Data - it
/// is not in the model, does not move any version hash, and Core Data never inspects
/// `sqlite_master` for indexes it did not create - while SQLite's planner will happily use one.
/// So the index is created directly, with a single `CREATE INDEX` pass over one table, rather
/// than by rewriting the store.
///
/// Safety comes from three things:
/// - It runs BEFORE `loadPersistentStores`, when nothing else has the file open, so there is no
///   concurrent access to a store Core Data is managing.
/// - It verifies the table and every column exists first, and skips silently if anything does not
///   look exactly as expected. A mismatch leaves the store untouched and the app behaves as it
///   does today.
/// - It runs once per store file per version, so only a single launch ever pays for it; every
///   launch after is a no-op with the same timing as before.
enum CoreDataIndexBuilder {

    /// One index to create. `entityName` and `attributes` are the MODEL's names - Core Data's
    /// SQLite naming (`CDMessage` -> `ZCDMESSAGE`, `walletAddress` -> `ZWALLETADDRESS`) is derived
    /// and then verified against the actual schema before anything is created.
    struct Spec {
        let entityName: String
        let attributes: [String]

        var tableName: String { "Z\(entityName.uppercased())" }
        var columnNames: [String] { attributes.map { "Z\($0.uppercased())" } }
        /// Prefixed so ours are distinguishable from anything Core Data creates, and so a future
        /// version can drop them by prefix if this ever needs undoing.
        var indexName: String { "kachat_idx_\(tableName)_\(attributes.joined(separator: "_"))" }
    }

    /// Bump when the specs change so existing stores build the new set.
    private static let schemaVersion = 1

    private static func doneKey(for storeURL: URL) -> String {
        "kachat_sqlite_indexes_v\(schemaVersion)_\(storeURL.lastPathComponent)"
    }

    /// Creates any missing indexes for `storeURL`. Call immediately before the store is added.
    ///
    /// Returns without touching anything when this store has already been done, when the file does
    /// not exist yet (a brand-new store gets its indexes from the model, which Core Data DOES
    /// apply at creation), or on any error at all.
    static func buildIndexesIfNeeded(storeURL: URL, specs: [Spec]) {
        let key = doneKey(for: storeURL)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            // Nothing to retrofit. Mark it done: Core Data applies the model's own indexes when
            // it creates the store, so this file will never need us.
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            AppLog.log("%@", "[CoreDataIndexBuilder] Could not open \(storeURL.lastPathComponent); leaving it alone")
            return
        }
        defer { sqlite3_close(db) }

        // A store mid-write from a previous run should not be waited on forever.
        sqlite3_busy_timeout(db, 3_000)

        let started = Date()
        var created = 0
        for spec in specs {
            guard tableExists(spec.tableName, db: db) else { continue }
            let existing = columns(of: spec.tableName, db: db)
            guard spec.columnNames.allSatisfy({ existing.contains($0) }) else {
                AppLog.log("%@", "[CoreDataIndexBuilder] Skipping \(spec.indexName): schema does not match the model")
                continue
            }
            let sql = "CREATE INDEX IF NOT EXISTS \(spec.indexName) ON \(spec.tableName) (\(spec.columnNames.joined(separator: ", ")))"
            if exec(sql, db: db) {
                created += 1
            } else {
                AppLog.log("%@", "[CoreDataIndexBuilder] Failed to create \(spec.indexName): \(lastError(db))")
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let elapsed = Date().timeIntervalSince(started)
        AppLog.log("%@", "[CoreDataIndexBuilder] \(storeURL.lastPathComponent): \(created) index(es) in \(String(format: "%.0f", elapsed * 1000))ms")
    }

    // MARK: - SQLite helpers

    private static func tableExists(_ table: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite must copy the string, since `table` may not outlive the step.
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columns(of table: String, db: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        // PRAGMA does not take bound parameters; `table` here is derived from our own hardcoded
        // entity names, never from anything external.
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: raw))
            }
        }
        return names
    }

    private static func exec(_ sql: String, db: OpaquePointer) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

/// Adds a store to its container OFF the main thread and reports back ON it.
///
/// Every store used to load synchronously on the main thread at launch and on every wallet
/// switch, with the SQLite index retrofit run on the same thread first. A migration or a
/// write-ahead-log recovery after the process was killed mid-write then blocked the very
/// thread iOS watches at launch, and past a few seconds that is a watchdog kill. Now the
/// retrofit and the add both run on a background queue, the caller waits without blocking,
/// and the store's flags flip on the main thread as before.
enum CoreDataStoreLoader {
    /// Cocoa error codes for a file the model cannot open: a store written by a model this
    /// build no longer understands, a migration with nothing to map it, or a corrupt file.
    private static let unusableStoreCodes: Set<Int> = [
        NSPersistentStoreIncompatibleVersionHashError,
        NSPersistentStoreIncompatibleSchemaError,
        NSMigrationError,
        NSMigrationMissingSourceModelError,
        NSMigrationMissingMappingModelError,
        NSFileReadCorruptFileError,
    ]

    static func load(
        container: NSPersistentContainer,
        description: NSPersistentStoreDescription,
        indexSpecs: [CoreDataIndexBuilder.Spec],
        completion: @escaping (Error?) -> Void
    ) {
        description.shouldAddStoreAsynchronously = true
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        DispatchQueue.global(qos: .userInitiated).async {
            // Before the store is added, while nothing else has the file open.
            if let url = description.url {
                CoreDataIndexBuilder.buildIndexesIfNeeded(storeURL: url, specs: indexSpecs)
            }
            container.loadPersistentStores { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// True when the file itself is the problem and a cache-only store may be rebuilt.
    static func isUnusableStore(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && unusableStoreCodes.contains(nsError.code)
    }

    /// Drops a store that was added for a description the container has since moved past -
    /// a wallet switch that overtook a load still in flight - so two files are never attached.
    static func detachStore(at url: URL?, from container: NSPersistentContainer) {
        guard let url, let stale = container.persistentStoreCoordinator.persistentStore(for: url) else { return }
        try? container.persistentStoreCoordinator.remove(stale)
    }

    /// Deletes the store file so the next load starts a fresh one. For caches of on-chain
    /// data only: the rows come back from the network, and a file the model cannot open
    /// would otherwise leave the feature dead until the app was reinstalled.
    static func destroyStore(at url: URL, in container: NSPersistentContainer) {
        do {
            try container.persistentStoreCoordinator.destroyPersistentStore(at: url, type: .sqlite, options: nil)
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
    }

    /// The user's message history could not be opened: nothing else in the app says so, and
    /// running on silently with no persistence was the old behaviour.
    static func reportFailure(store: String, error: Error) {
        AppLog.log("%@", "[\(store)] Failed to load store: \(error.localizedDescription)")
        NotificationCenter.default.post(
            name: .localStoreLoadFailed,
            object: nil,
            userInfo: ["store": store, "message": error.localizedDescription]
        )
    }
}

extension Notification.Name {
    /// A local Core Data store failed to open. userInfo: `store` (a name), `message`.
    static let localStoreLoadFailed = Notification.Name("localStoreLoadFailed")
}
