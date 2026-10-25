import FlaccyCore
import MidgarCore
import Foundation

/// Why a previous version could not be put back.
nonisolated enum PreviousVersionError: LocalizedError {
    case missing
    case swapFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missing:
            return String(localized: "the saved copy is no longer on this device")
        case .swapFailed(let underlying):
            return underlying.localizedDescription
        }
    }
}

/// The files a replaced song leaves behind: the version it had before, kept in
/// Application Support for 30 days so a new mix that turns out worse can be
/// swapped back. Every move is undone if a later step fails, so a song is never
/// left without its current file.
nonisolated enum PreviousVersions {

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Previous Versions", isDirectory: true)
    }

    static func storedURL(forRelativePath relativePath: String) -> URL {
        folder.appendingPathComponent(relativePath)
    }

    /// Moves the current file aside and puts the staged copy in its place. The
    /// older previous version, if any, is dropped only once the new one is safe.
    static func replace(
        current: URL, with staged: URL, relativePath: String, now: Date, database: DatabaseManager = .shared
    ) throws {
        let fileManager = FileManager.default
        let stored = storedURL(forRelativePath: relativePath)
        try fileManager.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aside = stored.deletingLastPathComponent().appendingPathComponent(".\(stored.lastPathComponent).flaccy-old")
        try? fileManager.removeItem(at: aside)
        let olderRow = try database.fetchPreviousVersion(trackFileURL: relativePath)
        let hadOlder = fileManager.fileExists(atPath: stored.path)
        if hadOlder {
            try fileManager.moveItem(at: stored, to: aside)
        }
        do {
            try fileManager.moveItem(at: current, to: stored)
        } catch {
            if hadOlder { try? fileManager.moveItem(at: aside, to: stored) }
            throw error
        }
        do {
            try database.upsertPreviousVersion(
                PreviousVersionRecord(trackFileURL: relativePath, storedPath: relativePath, movedAt: now)
            )
            try fileManager.moveItem(at: staged, to: current)
        } catch {
            try? fileManager.moveItem(at: stored, to: current)
            rollBackRow(olderRow, relativePath: relativePath, database: database)
            if hadOlder { try? fileManager.moveItem(at: aside, to: stored) }
            throw error
        }
        try? fileManager.removeItem(at: aside)
    }

    /// Swaps the current file with its previous version: what plays now becomes
    /// the previous version and the other way round, so restoring twice returns
    /// to where it started.
    static func swapWithPrevious(
        relativePath: String, libraryRoot: URL, now: Date, database: DatabaseManager = .shared
    ) throws {
        let fileManager = FileManager.default
        guard let record = try database.fetchPreviousVersion(trackFileURL: relativePath) else {
            throw PreviousVersionError.missing
        }
        let previous = folder.appendingPathComponent(record.storedPath)
        guard fileManager.fileExists(atPath: previous.path) else {
            try? database.deletePreviousVersion(trackFileURL: relativePath)
            throw PreviousVersionError.missing
        }
        let current = libraryRoot.appendingPathComponent(relativePath)
        let temporary = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).flaccy-swap")
        try? fileManager.removeItem(at: temporary)
        do {
            try fileManager.moveItem(at: current, to: temporary)
        } catch {
            throw PreviousVersionError.swapFailed(underlying: error)
        }
        do {
            try fileManager.moveItem(at: previous, to: current)
        } catch {
            try? fileManager.moveItem(at: temporary, to: current)
            throw PreviousVersionError.swapFailed(underlying: error)
        }
        do {
            try fileManager.moveItem(at: temporary, to: previous)
        } catch {
            try? fileManager.moveItem(at: current, to: previous)
            try? fileManager.moveItem(at: temporary, to: current)
            throw PreviousVersionError.swapFailed(underlying: error)
        }
        do {
            try database.upsertPreviousVersion(
                PreviousVersionRecord(trackFileURL: relativePath, storedPath: record.storedPath, movedAt: now)
            )
        } catch {
            MidgarLog.error("Previous version stamp failed for \(relativePath): \(error.localizedDescription)", category: .database)
        }
    }

    /// Drops every previous version older than the retention period, file and row.
    static func purgeExpired(now: Date, database: DatabaseManager = .shared) {
        let expired: [PreviousVersionRecord]
        do {
            expired = try database.fetchExpiredPreviousVersions(now: now)
        } catch {
            MidgarLog.error("Could not read expired previous versions: \(error.localizedDescription)", category: .database)
            return
        }
        guard !expired.isEmpty else { return }
        var purged = 0
        for record in expired {
            let file = folder.appendingPathComponent(record.storedPath)
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                try database.deletePreviousVersion(trackFileURL: record.trackFileURL)
                purged += 1
            } catch {
                MidgarLog.error("Could not purge previous version \(record.storedPath): \(error.localizedDescription)", category: .content)
            }
        }
        MidgarLog.info("Purged \(purged) of \(expired.count) expired previous versions", category: .content)
    }

    private static func rollBackRow(_ older: PreviousVersionRecord?, relativePath: String, database: DatabaseManager) {
        do {
            if let older {
                try database.upsertPreviousVersion(older)
            } else {
                try database.deletePreviousVersion(trackFileURL: relativePath)
            }
        } catch {
            MidgarLog.error("Could not roll back the previous version row for \(relativePath): \(error.localizedDescription)", category: .database)
        }
    }
}
