//
//  Persistence.swift
//  Spellline
//
//  Created by Florian Ritzmaier on 29.03.26.
//

import CoreData
import OSLog
import SQLite3

struct PersistenceController {
    static let shared = PersistenceController()
    private static let logger = Logger(subsystem: "xyz.floritzmaier.spellline", category: "Persistence")

    @MainActor
    static let preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Spellline")
        let storeURL: URL
        if inMemory {
            storeURL = URL(fileURLWithPath: "/dev/null")
            Self.logger.debug("Using in-memory Core Data store")
        } else {
            storeURL = Self.ensurePreloadedStore()
            Self.logger.info("Using Core Data store at \(storeURL.path, privacy: .public)")
        }
        let description = NSPersistentStoreDescription(url: storeURL)
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                Self.logger.error("Persistent store load failed: \(error.localizedDescription, privacy: .public)")
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.

                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
            Self.logger.info("Persistent store loaded: \(storeDescription.url?.path ?? "-", privacy: .public)")
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static func ensurePreloadedStore() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeDir = appSupport.appendingPathComponent("CoreDataStore", isDirectory: true)
        let destination = storeDir.appendingPathComponent("spellline.sqlite")

        if fm.fileExists(atPath: destination.path) {
            if validateStoreHasStops(at: destination) {
                Self.logger.info("Preloaded store already present at \(destination.path, privacy: .public)")
                return destination
            }
            Self.logger.warning("Existing store has no stops; replacing from bundle")
            removeExistingStoreFiles(at: destination)
        }

        do {
            try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let source = try bundledPreloadedStoreURL()
            try fm.copyItem(at: source, to: destination)
            Self.logger.info("Copied preloaded store from \(source.path, privacy: .public) to \(destination.path, privacy: .public)")

            let sourceWAL = source.deletingPathExtension().appendingPathExtension("sqlite-wal")
            let sourceSHM = source.deletingPathExtension().appendingPathExtension("sqlite-shm")
            let destinationWAL = destination.deletingPathExtension().appendingPathExtension("sqlite-wal")
            let destinationSHM = destination.deletingPathExtension().appendingPathExtension("sqlite-shm")

            if fm.fileExists(atPath: sourceWAL.path) {
                try? fm.copyItem(at: sourceWAL, to: destinationWAL)
            }
            if fm.fileExists(atPath: sourceSHM.path) {
                try? fm.copyItem(at: sourceSHM, to: destinationSHM)
            }
        } catch {
            Self.logger.error("Failed to copy preloaded store: \(error.localizedDescription, privacy: .public)")
            fatalError("Failed to copy preloaded store: \(error)")
        }

        if !validateStoreHasStops(at: destination) {
            Self.logger.error("Copied store validation failed: no rows in ZSTOP")
        } else {
            Self.logger.info("Copied store validation passed (ZSTOP > 0)")
        }

        return destination
    }

    private static func removeExistingStoreFiles(at destination: URL) {
        let fm = FileManager.default
        let wal = destination.deletingPathExtension().appendingPathExtension("sqlite-wal")
        let shm = destination.deletingPathExtension().appendingPathExtension("sqlite-shm")
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: wal)
        try? fm.removeItem(at: shm)
    }

    private static func validateStoreHasStops(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            Self.logger.error("Failed to open sqlite for validation at \(url.path, privacy: .public)")
            return false
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM ZSTOP;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Self.logger.error("Failed to prepare ZSTOP validation query")
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Self.logger.error("Validation query returned no row")
            return false
        }

        let count = sqlite3_column_int64(statement, 0)
        Self.logger.info("Store validation ZSTOP count: \(count, privacy: .public)")
        return count > 0
    }

    private static func bundledPreloadedStoreURL() throws -> URL {
        if let url = Bundle.main.url(forResource: "spellline", withExtension: "sqlite", subdirectory: "preloaded_store") {
            return url
        }
        if let url = Bundle.main.url(forResource: "spellline", withExtension: "sqlite") {
            return url
        }

        throw NSError(
            domain: "PersistenceController",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Bundled preloaded Core Data store not found"]
        )
    }
}
