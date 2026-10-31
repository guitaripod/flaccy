import FlaccyCore
import Foundation
import MidgarCore

/// The scan's running record of which files it is reading, kept beside the
/// database so the launch after a crash can tell which file stopped the app
/// (`ScanJournalReplay` reads it), and the files that did, which are filed by
/// their names instead of being read again.
///
/// A crash inside a system decoder cannot be caught the way the Rust scanner
/// catches a panicking file, so without this one malformed file would stop
/// every launch at the same point of the first scan. Writes are appends with
/// no sync: the page cache outlives a crashed process.
nonisolated final class ScanJournal: @unchecked Sendable {

    let replay: ScanJournalReplay
    let quarantined: Set<String>

    private let lock = NSLock()
    private let journalURL: URL
    private var handle: FileHandle?

    /// Reads what the last scan left, moves the files that crashed it alone
    /// into the quarantine (dropping quarantined files no longer on disk, so a
    /// file put back later gets a fresh read), then starts this scan's journal.
    init(onDisk diskPaths: Set<String>) {
        let directory = Self.directory
        journalURL = directory.appendingPathComponent("scan-journal.log")
        let left = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
        replay = ScanJournalReplay(journal: left)
        let held = Self.quarantinedPaths()
        let kept = held.union(replay.crashedAlone).intersection(diskPaths)
        quarantined = kept
        if kept != held { Self.writeQuarantine(kept) }
        for path in replay.crashedAlone.intersection(diskPaths) {
            MidgarLog.error("Scan stopped while reading \(path) on its own; filing it by name from now on", category: .content)
        }
        if !replay.suspects.isEmpty {
            MidgarLog.notice("The last scan stopped with \(replay.suspects.count) files in flight; reading them one at a time", category: .content)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: journalURL)
    }

    func note(_ mark: Character, _ path: String) {
        let line = Data(ScanJournalReplay.line(mark, path: path).utf8)
        lock.withLock { try? handle?.write(contentsOf: line) }
    }

    /// The scan finished: nothing it began can be blamed on the next launch.
    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// Files a scan has filed by name because reading them stopped the app,
    /// which the revision pass must not open either.
    static func quarantinedPaths() -> Set<String> {
        guard let data = try? Data(contentsOf: quarantineURL),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(paths)
    }

    private static func writeQuarantine(_ paths: Set<String>) {
        guard !paths.isEmpty else {
            try? FileManager.default.removeItem(at: quarantineURL)
            return
        }
        guard let data = try? JSONEncoder().encode(paths.sorted()) else { return }
        try? data.write(to: quarantineURL, options: .atomic)
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true)
    }

    private static var quarantineURL: URL {
        directory.appendingPathComponent("scan-quarantine.json")
    }
}
