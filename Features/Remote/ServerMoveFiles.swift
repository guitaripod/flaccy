import FlaccyCore
import FlaccyEngine
import Foundation

/// What taking the files of moved songs out of the library folder did.
nonisolated struct ServerMoveFileOutcome: Sendable, Equatable {
    var handled = 0
    var kept = 0
    var freedBytes: Int64 = 0
    /// Songs the person asked to keep whose file could not be put in place; they play from the server.
    var notKept = 0
    /// Files left for later because the player is reading them.
    var deferred = 0

    mutating func add(_ other: ServerMoveFileOutcome) {
        handled += other.handled
        kept += other.kept
        freedBytes += other.freedBytes
        notKept += other.notKept
        deferred += other.deferred
    }
}

/// Takes the files of songs that now play from a server out of the library folder, as the journal
/// in the database lists them: a song kept on the device becomes the server song's download, in
/// place of any copy the cache held, any other file is deleted (moved to the Trash on the Mac, where
/// the folder is the person's). It runs after a move and before every library scan, so a move a crash
/// interrupted finishes, and a file the player is reading waits for the next run, as does a kept file
/// that could not be put in place, which is never deleted. A song whose server row left the library,
/// or whose file was replaced by another, keeps the file, which the next scan lists again.
nonisolated enum ServerMoveFiles {

    static func finishPending(
        sparing inUse: Set<String> = [], progress: (@Sendable (Int) async -> Void)? = nil
    ) async -> ServerMoveFileOutcome {
        let database = DatabaseManager.shared
        guard let records = try? database.pendingServerMoves(), !records.isEmpty else { return ServerMoveFileOutcome() }
        var outcome = ServerMoveFileOutcome()
        var finished: [String] = []
        var folders = Set<URL>()
        for (index, record) in records.enumerated() {
            if let progress, index % 50 == 0 { await progress(index) }
            if inUse.contains(record.localPath) {
                outcome.deferred += 1
                continue
            }
            let file = LibraryPaths.root.appendingPathComponent(record.localPath, isDirectory: false)
            guard let song = RemoteTrackPath(path: record.remotePath), (try? database.hasRemoteRow(path: record.remotePath)) == true else {
                try? database.abandonServerMove(localPath: record.localPath)
                RemoteLog.notice("Kept \(record.localPath) on this device: its server song left the library before the move finished")
                continue
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                outcome.handled += 1
                finished.append(record.localPath)
                continue
            }
            let bytes = Self.size(of: file)
            if let expected = record.fileSize, expected != bytes {
                try? database.abandonServerMove(localPath: record.localPath)
                RemoteLog.notice("Kept \(record.localPath): a different file took its place before the move finished")
                continue
            }
            folders.insert(file.deletingLastPathComponent())
            if record.keepOnDevice {
                do {
                    try await RemoteStreamCache.shared.adoptDeviceCopy(file, for: song, byCopying: Self.copiesKeptFiles)
                    outcome.kept += 1
                    if Self.copiesKeptFiles, !Self.remove(file) { continue }
                    outcome.handled += 1
                    finished.append(record.localPath)
                } catch {
                    RemoteLog.error("Could not keep \(record.localPath) as the download of \(record.remotePath), left it for the next try: \(error.localizedDescription)")
                    outcome.notKept += 1
                }
                continue
            }
            guard Self.remove(file) else { continue }
            outcome.freedBytes += bytes
            outcome.handled += 1
            finished.append(record.localPath)
        }
        try? database.finishServerMoves(localPaths: finished)
        Self.pruneEmptyFolders(folders)
        if let progress { await progress(records.count) }
        if outcome.handled > 0 || outcome.deferred > 0 {
            RemoteLog.info("Moved files: \(outcome.handled) handled, \(outcome.kept) kept, \(outcome.freedBytes) bytes freed, \(outcome.notKept) not kept, \(outcome.deferred) waiting for the player")
        }
        return outcome
    }

    /// On the Mac the library folder is the person's, so a kept file is copied into the app's downloads and the original goes
    /// to the Trash; on iPhone and iPad it is moved within the app's own storage.
    private static var copiesKeptFiles: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @discardableResult
    private static func remove(_ file: URL) -> Bool {
        do {
            #if os(macOS)
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: file)
            #endif
            return true
        } catch {
            RemoteLog.error("Could not remove \(file.lastPathComponent) after its song moved to the server: \(error.localizedDescription)")
            return false
        }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Removes the folders the move emptied, walking up to the library folder, which always stays.
    private static func pruneEmptyFolders(_ folders: Set<URL>) {
        let root = LibraryPaths.root.standardizedFileURL.path
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            var current = folder.standardizedFileURL
            while current.path.hasPrefix(root + "/"), Self.isEmptyFolder(current) {
                try? FileManager.default.removeItem(at: current)
                current = current.deletingLastPathComponent()
            }
        }
    }

    private static func isEmptyFolder(_ folder: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return contents.allSatisfy { $0 == ".DS_Store" }
    }
}
