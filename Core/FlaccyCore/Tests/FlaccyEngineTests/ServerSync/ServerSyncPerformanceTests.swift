import Darwin
import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

/// Measures the sync engine on a library the size of a heavy listener's. Set `FLACCY_PERF=1`; build with
/// `-c release -Xswiftc -enable-testing` for numbers that mean something.
final class ServerSyncPerformanceTests: XCTestCase {

    static let trackCount = 7_500
    static let playlistCount = 200
    static let largestPlaylist = 2_000
    static let scrobbleCount = 165_000

    private func report(_ line: String) {
        FileHandle.standardError.write(Data("PERF \(line)\n".utf8))
    }

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func residentMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    private func currentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private func buildLibrary(_ device: SyncDevice) throws {
        let database = device.database
        let tracks = (0..<Self.trackCount).map { index in
            TrackRecord(
                fileURL: "Artist \(index % 600)/Album \(index % 900)/Song \(index).flac", title: "Song \(index)",
                artist: "Artist \(index % 600)", albumTitle: "Album \(index % 900)", trackNumber: index % 14 + 1,
                duration: 180 + Double(index % 120), dateAdded: Date(), playCount: 0, aiAnalyzed: false,
                codec: index % 5 == 0 ? "MP3" : "FLAC", loved: index % 20 != 0
            )
        }
        try database.insertTracks(tracks)
        for playlist in 0..<Self.playlistCount {
            let size = playlist == 0 ? Self.largestPlaylist : 20 + (playlist * 7) % 81
            let id = try XCTUnwrap(database.createPlaylist(name: "Playlist \(playlist)").id)
            try database.addTracksToPlaylist(
                playlistId: id, trackFileURLs: (0..<size).map { tracks[($0 * 13 + playlist * 31) % tracks.count].fileURL }
            )
        }
        try device.write { db in
            var memo = ListenKeyMemo()
            let insert = try db.cachedStatement(sql: """
                INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted, titleKey, artistKey, albumKey)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                """)
            let start = 1_500_000_000.0
            for index in 0..<Self.scrobbleCount {
                let track = tracks[(index * 7919) % Self.trackCount]
                let keys = memo.keys(title: track.title, artist: track.artist, album: track.albumTitle)
                let when = Date(timeIntervalSince1970: start + Double(index) * 800)
                let played = index % 5 < 3 ? 0 : 200
                let arguments: [any DatabaseValueConvertible] = [
                    track.title, track.artist, track.albumTitle, when, played, keys.title, keys.artist, keys.album,
                ]
                try insert.execute(arguments: StatementArguments(arguments))
            }
        }
    }

    private final class WriterProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var longest = 0.0
        private var running = true

        func start(_ database: DatabaseManager) -> Thread {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let begun = DispatchTime.now().uptimeNanoseconds
                    try? database.dbQueue.write { _ in }
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1_000_000
                    lock.withLock { longest = max(longest, waited) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            thread.start()
            return thread
        }

        func stop() -> Double {
            lock.withLock { running = false }
            Thread.sleep(forTimeInterval: 0.05)
            return lock.withLock { longest }
        }
    }

    func testARealisticLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLACCY_PERF"] != nil)
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let built = try milliseconds { try buildLibrary(device) }
        report("built \(Self.trackCount) tracks, \(Self.playlistCount) playlists, \(Self.scrobbleCount) scrobbles in \(Int(built)) ms")
        try device.database.fillListenKeys()
        try device.write { try $0.execute(sql: "ANALYZE") }
        report("memory after the build: now \(Int(currentMegabytes())) MB, peak \(Int(residentMegabytes())) MB")

        try statsComparison(device)
        try await importMeasurement(device, server: server)
        try pullMeasurement(device, server: server)
        try indexMeasurement(device)
    }

    private func importMeasurement(_ device: SyncDevice, server: FakeFlaccyServer) async throws {
        let probe = WriterProbe()
        _ = probe.start(device.database)
        let before = residentMegabytes()
        let link = FlaccyServerLink(baseURL: SyncDevice.link.baseURL, enrollmentCode: "GOODCODE", name: "Fake")
        let started = DispatchTime.now().uptimeNanoseconds
        let connection = try await Task.detached { try await device.engine.connect(link: link, deviceName: "Perf", startSyncing: false) }.value
        let connected = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let afterConnect = probe.stop()
        report("memory after connect: now \(Int(currentMegabytes())) MB, peak \(Int(residentMegabytes())) MB")
        report("connect (structure import): \(Int(connected)) ms, longest writer wait \(Int(afterConnect)) ms, \(connection.imported)")

        let probeTwo = WriterProbe()
        _ = probeTwo.start(device.database)
        let store = ServerSyncStore(database: device.database)
        var chunks = 0
        var slowestChunk = 0.0
        let listensStart = DispatchTime.now().uptimeNanoseconds
        while true {
            var done = false
            let took = try milliseconds { done = try store.importListensChunk().done }
            slowestChunk = max(slowestChunk, took)
            if done { break }
            chunks += 1
        }
        let listens = Double(DispatchTime.now().uptimeNanoseconds - listensStart) / 1_000_000
        let waited = probeTwo.stop()
        let pending = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_pending") }
        report("listen import: \(Int(listens)) ms in \(chunks) chunks, slowest chunk \(Int(slowestChunk)) ms, longest writer wait \(Int(waited)) ms, \(pending ?? 0) pending mutations")
        report("memory after the listen import: now \(Int(currentMegabytes())) MB, peak \(Int(residentMegabytes())) MB (peak before the import \(Int(before)) MB)")
    }

    private func change(_ seq: Int64, _ kind: String, _ id: String, _ value: ServerJSON) -> ServerChange {
        ServerChange(seq: seq, kind: ServerEntityKind.named(kind), id: id, deleted: false, value: value)
    }

    private func pullMeasurement(_ device: SyncDevice, server: FakeFlaccyServer) throws {
        let store = ServerSyncStore(database: device.database)
        let link = try XCTUnwrap(store.link())
        var changes: [ServerChange] = []
        var seq: Int64 = 0
        let stamps: ServerJSON = ["name": 1, "cover": 1, "visibility": 1, "alive": 1]
        for playlist in 0..<100 {
            seq += 1
            let id = "00000000-0000-8000-8000-\(String(format: "%012d", playlist))"
            let value: ServerJSON = [
                "id": .string(id), "owner": .string(link.user), "name": .string("Remote \(playlist)"), "coverBlob": .null,
                "visibility": "private", "alive": .bool(true), "createdAt": 1_700_000_000, "stamps": stamps,
            ]
            changes.append(change(seq, "playlist", id, value))
            for entry in 0..<20 {
                seq += 1
                let song = (playlist * 20 + entry) % Self.trackCount
                let ref = try ServerSongIdentity.ref(title: "Song \(song)", artist: "Artist \(song % 600)", album: "Album \(song % 900)")
                let entryID = "10000000-0000-8000-8000-\(String(format: "%012d", playlist * 20 + entry))"
                let entryValue: ServerJSON = [
                    "id": .string(entryID), "playlist": .string(id), "ref": try ServerCoreBridge.json(ref),
                    "pos": .string("a\(String(format: "%05d", entry))V"), "alive": .bool(true),
                    "stamps": ["ref": 1, "pos": 1, "alive": 1],
                ]
                changes.append(change(seq, "playlist_entry", entryID, entryValue))
            }
        }
        var loveSeq = 0
        while changes.count < 5_000 {
            seq += 1
            let song = (loveSeq * 3) % Self.trackCount
            loveSeq += 1
            let ref = try ServerSongIdentity.ref(title: "Song \(song)", artist: "Artist \(song % 600)", album: "Album \(song % 900)")
            let loveValue: ServerJSON = [
                "songKey": .string(ref.songKey), "ref": try ServerCoreBridge.json(ref), "loved": .bool(loveSeq % 4 != 0),
                "stamp": .int(Int64(loveSeq)),
            ]
            changes.append(change(seq, "love", ref.songKey, loveValue))
        }
        let request = try store.pullRequest()
        let response = ServerPullResponse(
            head: seq, incarnation: link.incarnation ?? "", lastMutationId: 0, more: false, serverTimeMs: 0, changes: changes
        )
        var dirty = SyncDirty()
        let putTime = try milliseconds {
            for chunk in changes.chunked(into: 400) {
                try device.write { db in
                    for change in chunk {
                        if let stored = try SyncBase.put(db, change), let key = stored.foldKey { dirty.add(foldKey: key) }
                    }
                }
            }
        }
        var materializeTime = 0.0
        var cold = SyncDirty()
        cold.playlists = dirty.playlists
        let playlistsOnly = try milliseconds { _ = try store.materialize(cold) }
        var lovesOnly = SyncDirty()
        lovesOnly.loves = dirty.loves
        materializeTime = try milliseconds { _ = try store.materialize(lovesOnly) }
        report("profile: put \(Int(putTime)) ms for \(changes.count) changes; materialize \(dirty.playlists.count) playlists \(Int(playlistsOnly)) ms, \(dirty.loves.count) loves \(Int(materializeTime)) ms")
        let beforePage = currentMegabytes()
        report("memory with the 5000 changes built, before applying them: \(Int(beforePage)) MB")
        let probe = WriterProbe()
        _ = probe.start(device.database)
        let page = try milliseconds { _ = try store.onPullPage(request: request, response: response, localNowMs: 0) }
        report("pull page of \(changes.count) changes (100 playlists, 2000 entries, rest loves): \(Int(page)) ms, longest writer wait \(Int(probe.stop())) ms")
        report("memory after the 5000-change page: now \(Int(currentMegabytes())) MB, peak \(Int(residentMegabytes())) MB")

        try bigPlaylistPull(store, link: link, firstSeq: seq + 1)
        let listenStart = (1_700_000_000 as Int64)
        let listenProbe = WriterProbe()
        _ = listenProbe.start(device.database)
        let slowest = try measureListens(store, pages: 4, perPage: 5_000, start: listenStart)
        report("longest writer wait while 20000 listens were applied: \(Int(listenProbe.stop())) ms")
        report("20000 listens in 4 pages: slowest page \(Int(slowest.slowest)) ms, total \(Int(slowest.total)) ms")
        report("memory after the pulls: now \(Int(currentMegabytes())) MB, peak \(Int(residentMegabytes())) MB")
    }

    private func bigPlaylistPull(_ store: ServerSyncStore, link: ServerSyncLink, firstSeq: Int64) throws {
        var changes: [ServerChange] = []
        var seq = firstSeq
        let id = "00000000-0000-8000-8000-999999999999"
        let value: ServerJSON = [
            "id": .string(id), "owner": .string(link.user), "name": "Remote big", "coverBlob": .null,
            "visibility": "private", "alive": .bool(true), "createdAt": 1_700_000_000,
            "stamps": ["name": 1, "cover": 1, "visibility": 1, "alive": 1],
        ]
        changes.append(change(seq, "playlist", id, value))
        for entry in 0..<Self.largestPlaylist {
            seq += 1
            let song = (entry * 17) % Self.trackCount
            let ref = try ServerSongIdentity.ref(title: "Song \(song)", artist: "Artist \(song % 600)", album: "Album \(song % 900)")
            let entryID = "20000000-0000-8000-8000-\(String(format: "%012d", entry))"
            let entryValue: ServerJSON = [
                "id": .string(entryID), "playlist": .string(id), "ref": try ServerCoreBridge.json(ref),
                "pos": .string("a\(String(format: "%05d", entry))V"), "alive": .bool(true), "stamps": ["ref": 1, "pos": 1, "alive": 1],
            ]
            changes.append(change(seq, "playlist_entry", entryID, entryValue))
        }
        let request = try store.pullRequest()
        let response = ServerPullResponse(head: seq, incarnation: link.incarnation ?? "", lastMutationId: 0, more: false, serverTimeMs: 0, changes: changes)
        let probe = WriterProbe()
        _ = probe.start(store.database)
        let took = try milliseconds { _ = try store.onPullPage(request: request, response: response, localNowMs: 0) }
        report("pull of one playlist with \(Self.largestPlaylist) entries: \(Int(took)) ms, longest writer wait \(Int(probe.stop())) ms")
    }

    private func measureListens(_ store: ServerSyncStore, pages: Int, perPage: Int, start: Int64) throws -> (slowest: Double, total: Double) {
        var slowest = 0.0
        var total = 0.0
        var seq: Int64 = 0
        for page in 0..<pages {
            var items: [ServerListenItem] = []
            for index in 0..<perPage {
                seq += 1
                let song = (page * perPage + index) % Self.trackCount
                items.append(ServerListenItem(
                    seq: seq, eventId: String(format: "%024x", Int(seq) + 1_000_000_000), ts: start + seq * 90,
                    ref: try ServerSongIdentity.ref(title: "Song \(song)", artist: "Artist \(song % 600)", album: "Album \(song % 900)"),
                    playedS: 200
                ))
            }
            let took = try milliseconds {
                _ = try store.onListensPage(ServerListensPage(listens: items, more: page < pages - 1, head: Int64(pages * perPage)))
            }
            slowest = max(slowest, took)
            total += took
        }
        return (slowest, total)
    }

    private func indexMeasurement(_ device: SyncDevice) throws {
        let database = device.database
        try device.write { try $0.execute(sql: "DELETE FROM sync_song_keys") }
        let first = try milliseconds { try SyncSongRefs.refreshIndex(database) }
        let again = try milliseconds { try SyncSongRefs.refreshIndex(database) }
        let rows = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_song_keys") }
        report("song key index: first fill \(Int(first)) ms for \(rows ?? 0) tracks, unchanged refresh \(String(format: "%.1f", again)) ms")
    }

    private struct Query {
        var name: String
        var old: String
        var new: String
        var arguments: StatementArguments = []
    }

    private func statsComparison(_ device: SyncDevice) throws {
        let year = Date(timeIntervalSince1970: 1_560_000_000)
        let nextYear = Date(timeIntervalSince1970: 1_591_536_000)
        let window = "timestamp >= ?1 AND timestamp < ?2"
        let queries: [Query] = [
            Query(name: "timestamps since", old: "SELECT timestamp FROM scrobbles WHERE timestamp >= ?1 ORDER BY timestamp ASC",
                  new: "SELECT timestamp FROM scrobbles WHERE suppressed = 0 AND timestamp >= ?1 ORDER BY timestamp ASC", arguments: [year]),
            Query(name: "rows in a year", old: "SELECT * FROM scrobbles WHERE \(window) ORDER BY timestamp ASC",
                  new: "SELECT * FROM scrobbles WHERE suppressed = 0 AND \(window) ORDER BY timestamp ASC", arguments: [year, nextYear]),
            Query(name: "years", old: "SELECT DISTINCT CAST(strftime('%Y', timestamp) AS INTEGER) FROM scrobbles WHERE timestamp >= ?1 ORDER BY 1 DESC",
                  new: "SELECT DISTINCT CAST(strftime('%Y', timestamp) AS INTEGER) FROM scrobbles WHERE suppressed = 0 AND timestamp >= ?1 ORDER BY 1 DESC",
                  arguments: [Date(timeIntervalSince1970: 1_009_843_200)]),
            Query(name: "all rows", old: "SELECT * FROM scrobbles ORDER BY timestamp ASC", new: "SELECT * FROM scrobbles WHERE suppressed = 0 ORDER BY timestamp ASC"),
            Query(name: "play count by track", old: "SELECT titleKey, artistKey, COUNT(*) AS c FROM scrobbles GROUP BY titleKey, artistKey ORDER BY c DESC",
                  new: "SELECT titleKey, artistKey, COUNT(*) AS c FROM scrobbles WHERE suppressed = 0 GROUP BY titleKey, artistKey ORDER BY c DESC"),
            Query(name: "last played by album", old: "SELECT albumTitle, artist, MAX(timestamp), COUNT(*) FROM scrobbles GROUP BY albumTitle, artist",
                  new: "SELECT albumTitle, artist, MAX(timestamp), COUNT(*) FROM scrobbles WHERE suppressed = 0 GROUP BY albumTitle, artist"),
            Query(name: "count in range", old: "SELECT COUNT(*) FROM scrobbles WHERE \(window)",
                  new: "SELECT COUNT(*) FROM scrobbles WHERE suppressed = 0 AND \(window)", arguments: [year, nextYear]),
            Query(name: "totals, whole table", old: "SELECT COUNT(*), COALESCE(SUM(duration), 0) FROM scrobbles",
                  new: "SELECT COUNT(*), COALESCE(SUM(duration), 0) FROM scrobbles WHERE suppressed = 0"),
            Query(name: "totals, a year", old: "SELECT COUNT(*), COALESCE(SUM(duration), 0) FROM scrobbles WHERE \(window)",
                  new: "SELECT COUNT(*), COALESCE(SUM(duration), 0) FROM scrobbles WHERE suppressed = 0 AND \(window)", arguments: [year, nextYear]),
            Query(name: "unrecorded lengths", old: "SELECT titleKey, artistKey, artist, COUNT(*) FROM scrobbles WHERE duration = 0 GROUP BY titleKey, artistKey, artist",
                  new: "SELECT titleKey, artistKey, artist, COUNT(*) FROM scrobbles WHERE suppressed = 0 AND duration = 0 GROUP BY titleKey, artistKey, artist"),
            Query(name: "top tracks, whole table", old: "SELECT titleKey || char(31) || artistKey, trackTitle || char(31) || artist, COUNT(*) FROM scrobbles GROUP BY titleKey, artistKey, trackTitle, artist",
                  new: "SELECT titleKey || char(31) || artistKey, trackTitle || char(31) || artist, COUNT(*) FROM scrobbles WHERE suppressed = 0 GROUP BY titleKey, artistKey, trackTitle, artist"),
            Query(name: "top tracks, a year", old: "SELECT titleKey, artistKey, trackTitle, artist, COUNT(*) FROM scrobbles WHERE \(window) GROUP BY titleKey, artistKey, trackTitle, artist",
                  new: "SELECT titleKey, artistKey, trackTitle, artist, COUNT(*) FROM scrobbles WHERE suppressed = 0 AND \(window) GROUP BY titleKey, artistKey, trackTitle, artist",
                  arguments: [year, nextYear]),
            Query(name: "quarter hours, a year", old: "SELECT CAST(strftime('%s', timestamp) AS INTEGER) / 900 AS b, COUNT(*) FROM scrobbles WHERE \(window) GROUP BY b",
                  new: "SELECT CAST(strftime('%s', timestamp) AS INTEGER) / 900 AS b, COUNT(*) FROM scrobbles WHERE suppressed = 0 AND \(window) GROUP BY b",
                  arguments: [year, nextYear]),
            Query(name: "quarter hours, whole table", old: "SELECT CAST(strftime('%s', timestamp) AS INTEGER) / 900 AS b, COUNT(*) FROM scrobbles GROUP BY b",
                  new: "SELECT CAST(strftime('%s', timestamp) AS INTEGER) / 900 AS b, COUNT(*) FROM scrobbles WHERE suppressed = 0 GROUP BY b"),
            Query(name: "album listen count", old: "SELECT COUNT(*) FROM scrobbles WHERE titleKey = 'song 5' AND artistKey = 'artist 5' AND (albumKey = 'album 5' OR albumKey = '')",
                  new: "SELECT COUNT(*) FROM scrobbles WHERE suppressed = 0 AND titleKey = 'song 5' AND artistKey = 'artist 5' AND (albumKey = 'album 5' OR albumKey = '')"),
            Query(name: "pending submissions", old: "SELECT * FROM scrobbles WHERE submitted = 0 ORDER BY timestamp ASC",
                  new: "SELECT * FROM scrobbles WHERE submitted = 0 AND suppressed = 0 ORDER BY timestamp ASC"),
            Query(name: "tallies", old: "SELECT titleKey, artistKey, COUNT(*), MAX(timestamp) FROM scrobbles GROUP BY titleKey, artistKey",
                  new: "SELECT titleKey, artistKey, COUNT(*), MAX(timestamp) FROM scrobbles WHERE suppressed = 0 GROUP BY titleKey, artistKey"),
        ]
        for query in queries {
            let old = try median { try device.read { _ = try Row.fetchAll($0, sql: query.old, arguments: query.arguments) } }
            let new = try median { try device.read { _ = try Row.fetchAll($0, sql: query.new, arguments: query.arguments) } }
            let plan = try device.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + query.new, arguments: query.arguments) }
                .map { $0["detail"] as String }.joined(separator: " | ")
            let ratio = old > 0 ? new / old : 1
            report("query \(query.name): before \(String(format: "%.1f", old)) ms, after \(String(format: "%.1f", new)) ms (x\(String(format: "%.2f", ratio))) plan: \(plan)")
        }
    }

    private func median(_ body: () throws -> Void) throws -> Double {
        _ = try milliseconds(body)
        let samples = try (0..<9).map { _ in try milliseconds(body) }.sorted()
        return samples[4]
    }
}
