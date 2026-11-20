import FlaccyCore
import FlaccyEngine
import MidgarCore
import Foundation

extension Library {

    private nonisolated static let trackNumberRepairKey = "flaccy.trackNumberRepair"
    private nonisolated static let trackNumberRepairVersion = 1
    private nonisolated static let maxTrackNumberReadsInFlight = 8
    private nonisolated static let trackNumberReadLimit: Duration = .seconds(20)

    /// Reads the track numbers back once for songs an earlier build filed
    /// at 0: it read no number from an MP3's `TRCK` or an M4A's `trkn`, so
    /// those albums played and listed in title order. Runs after the first
    /// load has settled and marks itself done only when it finished.
    func repairMissingTrackNumbersOnce() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.trackNumberRepairKey) < Self.trackNumberRepairVersion else { return }
        Task {
            let repaired = await readMissingTrackNumbers()
            guard let repaired else { return }
            defaults.set(Self.trackNumberRepairVersion, forKey: Self.trackNumberRepairKey)
            guard repaired > 0 else { return }
            MidgarLog.info("Track numbers: filled \(repaired) songs filed without one", category: .content)
            await reloadFromDatabase()
        }
    }

    /// The number of rows that gained a track number, or nil when the
    /// database could not be read or written and the repair should run again.
    @concurrent
    nonisolated private func readMissingTrackNumbers() async -> Int? {
        let paths: [String]
        do {
            paths = try db.fetchLocalPathsWithoutTrackNumber()
        } catch {
            MidgarLog.error("Track number repair could not read the library: \(error.localizedDescription)", category: .database)
            return nil
        }
        guard !paths.isEmpty else { return 0 }
        let root = documentsDirectory
        var found: [String: Int] = [:]
        await withTaskGroup(of: (String, Int).self) { group in
            var pending = paths.makeIterator()
            func addNext() -> Bool {
                guard let path = pending.next() else { return false }
                group.addTask { (path, await Self.taggedTrackNumber(of: root.appendingPathComponent(path, isDirectory: false))) }
                return true
            }
            var inflight = 0
            while inflight < Self.maxTrackNumberReadsInFlight && addNext() { inflight += 1 }
            for await (path, number) in group {
                if number > 0 { found[path] = number }
                _ = addNext()
            }
        }
        do {
            return try db.fillMissingTrackNumbers(found)
        } catch {
            MidgarLog.error("Track number repair could not write: \(error.localizedDescription)", category: .database)
            return nil
        }
    }

    /// The track number the file's tags name, without loading its picture,
    /// or 0 when the file is gone, names none or cannot be read in time.
    nonisolated private static func taggedTrackNumber(of url: URL) async -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let read = await Deadline.value(within: trackNumberReadLimit) {
            await AudioMetadataReader.read(from: url, wantsArtwork: { _, _ in false }).trackNumber
        }
        return read ?? 0
    }
}
