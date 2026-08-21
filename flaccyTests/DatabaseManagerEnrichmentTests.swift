import FlaccyCore
import XCTest
@testable import flaccy

/// The Apple half of the cross-language enrichment proof. `DatabaseManager`'s
/// queue statements are `EnrichmentPolicy` and `EnrichmentKey` rewritten as SQL,
/// and only a test can tell when the two stop agreeing: a drifted predicate or a
/// mis-derived key does not error, it silently re-enriches the entire library and
/// lets the orphan sweep delete state that is still live. Rust proves its own
/// half in `linux/shared/src/enrichment_job.rs`; these are the same shapes, not
/// the same bytes, and the `aiBatch` scope exists nowhere else to prove.
nonisolated final class DatabaseManagerEnrichmentTests: XCTestCase {

    private let db = DatabaseManager.shared
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var namespace = ""
    private var insertedPaths: [String] = []

    override func setUp() {
        super.setUp()
        namespace = "flaccyTests-\(UUID().uuidString)"
        insertedPaths = []
    }

    override func tearDown() {
        for path in insertedPaths {
            if let track = try? db.fetchTrack(byRelativePath: path), let id = track.id {
                try? db.deleteTrack(id: id)
            }
        }
        let survivors = try? db.fetchTrackSortKeys().map { $0.fileURL }
        try? db.deleteTracksNotIn(relativePaths: Set(survivors ?? []))
        super.tearDown()
    }

    func testDueAlbumKeysAgreesWithEnrichmentPolicy() throws {
        let scope = EnrichmentScope.album
        var records: [TrackRecord] = []
        var expected: Set<String> = []
        var fixtures: Set<String> = []

        let unseeded = "\(namespace) album unseeded"
        records.append(makeTrack(album: unseeded, artist: namespace))
        fixtures.insert(EnrichmentKey.album(title: unseeded, artist: namespace))
        expected.insert(EnrichmentKey.album(title: unseeded, artist: namespace))

        for (index, state) in states(for: scope).enumerated() {
            let title = "\(namespace) album \(index)"
            records.append(makeTrack(album: title, artist: namespace))
            var record = state
            record.key = EnrichmentKey.album(title: title, artist: namespace)
            fixtures.insert(record.key)
            if EnrichmentPolicy.isDue(record, scope: scope, now: now) { expected.insert(record.key) }
            try db.upsertEnrichmentRecord(record)
        }
        try db.insertTracks(records)

        let due = try db.dueAlbumKeys(version: scope.currentVersion, now: now, limit: 10_000)
        let keys = due.map { EnrichmentKey.album(title: $0.title, artist: $0.artist) }
        XCTAssertEqual(Set(keys).intersection(fixtures), expected)
        XCTAssertEqual(try db.countDue(scope: scope, version: scope.currentVersion, now: now), due.count)
    }

    func testDueArtistNamesAgreesWithEnrichmentPolicy() throws {
        let scope = EnrichmentScope.artist
        var records: [TrackRecord] = []
        var expected: Set<String> = []
        var fixtures: Set<String> = []

        for (index, state) in states(for: scope).enumerated() {
            let artist = "\(namespace) artist \(index)"
            records.append(makeTrack(album: "\(artist) album", artist: artist))
            var record = state
            record.key = EnrichmentKey.artist(artist)
            fixtures.insert(record.key)
            if EnrichmentPolicy.isDue(record, scope: scope, now: now) { expected.insert(record.key) }
            try db.upsertEnrichmentRecord(record)
        }
        try db.insertTracks(records)

        let due = try db.dueArtistNames(version: scope.currentVersion, now: now, limit: 10_000)
        XCTAssertEqual(Set(due.map(EnrichmentKey.artist)).intersection(fixtures), expected)
        XCTAssertEqual(try db.countDue(scope: scope, version: scope.currentVersion, now: now), due.count)
    }

    func testDueAIBatchDirectoriesAgreesWithEnrichmentPolicy() throws {
        let scope = EnrichmentScope.aiBatch
        var records: [TrackRecord] = []
        var expected: Set<String> = []
        var fixtures: Set<String> = []

        for (index, state) in states(for: scope).enumerated() {
            let directory = "\(namespace)/Bjǫrk \(index)"
            records.append(makeTrack(album: "\(namespace) ai \(index)", artist: namespace, directory: directory, aiAnalyzed: false))
            var record = state
            record.key = EnrichmentKey.aiBatch(directory: directory)
            fixtures.insert(record.key)
            if EnrichmentPolicy.isDue(record, scope: scope, now: now) { expected.insert(record.key) }
            try db.upsertEnrichmentRecord(record)
        }
        let analyzed = "\(namespace)/already analyzed"
        records.append(makeTrack(album: "\(namespace) ai analyzed", artist: namespace, directory: analyzed, aiAnalyzed: true))
        try db.insertTracks(records)

        let due = try db.dueAIBatchDirectories(version: scope.currentVersion, now: now, limit: 10_000)
        let keys = due.map { EnrichmentKey.aiBatch(directory: $0) }
        XCTAssertEqual(Set(keys).intersection(fixtures), expected)
        XCTAssertFalse(keys.contains(EnrichmentKey.aiBatch(directory: analyzed)))
        XCTAssertEqual(try db.countDue(scope: scope, version: scope.currentVersion, now: now), due.count)
    }

    /// SQLite's `lower()` folds ASCII only and its `trim()` strips spaces alone,
    /// so a queue that derived its own key would miss every accented album the
    /// app had already settled — forever, and the sweep would delete the row.
    func testNonASCIIAlbumKeysAgreeBetweenSQLAndEnrichmentKey() throws {
        let settled = nonASCIIAlbums()
        try db.insertTracks(settled.map { makeTrack(album: $0.title, artist: $0.artist) })
        for album in settled {
            try db.upsertEnrichmentRecord(EnrichmentRecord(
                scope: .album,
                key: EnrichmentKey.album(title: album.title, artist: album.artist),
                version: EnrichmentScope.album.currentVersion,
                status: .satisfied,
                fields: EnrichmentFields.required(for: .album)
            ))
        }

        let due = try db.dueAlbumKeys(version: EnrichmentScope.album.currentVersion, now: now, limit: 10_000)
        let keys = Set(due.map { EnrichmentKey.album(title: $0.title, artist: $0.artist) })
        for album in settled {
            XCTAssertFalse(keys.contains(EnrichmentKey.album(title: album.title, artist: album.artist)), album.title)
        }
    }

    func testOrphanSweepKeepsStateForAlbumsTheLibraryStillHas() throws {
        let staying = nonASCIIAlbums()
        let leaving = (title: "\(namespace) removed", artist: namespace)
        let stayingTracks = staying.map { makeTrack(album: $0.title, artist: $0.artist) }
        let leavingTrack = makeTrack(album: leaving.title, artist: leaving.artist)
        try db.insertTracks(stayingTracks + [leavingTrack])

        for album in staying + [leaving] {
            try db.upsertEnrichmentRecord(EnrichmentRecord(
                scope: .album,
                key: EnrichmentKey.album(title: album.title, artist: album.artist),
                status: .exhausted,
                attempts: EnrichmentScope.album.maxAttempts
            ))
        }

        let survivors = Set(try db.fetchTrackSortKeys().map { $0.fileURL }).subtracting([leavingTrack.fileURL])
        try db.deleteTracksNotIn(relativePaths: survivors)

        for album in staying {
            let key = EnrichmentKey.album(title: album.title, artist: album.artist)
            XCTAssertNotNil(try db.fetchEnrichmentRecord(scope: .album, key: key), album.title)
        }
        let orphan = EnrichmentKey.album(title: leaving.title, artist: leaving.artist)
        XCTAssertNil(try db.fetchEnrichmentRecord(scope: .album, key: orphan))
    }

    /// A coverless tile is the visible gap in the grid, so the queue drains those
    /// first regardless of how the album sorts alphabetically.
    func testDueAlbumKeysOrdersCoverlessAlbumsFirst() throws {
        let covered = "\(namespace) aaa covered"
        let coverless = "\(namespace) zzz coverless"
        try db.insertTracks([
            makeTrack(album: covered, artist: namespace, artwork: Data(repeating: 0xAB, count: 4_096)),
            makeTrack(album: coverless, artist: namespace),
        ])

        let due = try db.dueAlbumKeys(version: EnrichmentScope.album.currentVersion, now: now, limit: 10_000)
        let titles = due.map(\.title)
        let coverlessIndex = try XCTUnwrap(titles.firstIndex(of: coverless))
        let coveredIndex = try XCTUnwrap(titles.firstIndex(of: covered))
        XCTAssertLessThan(coverlessIndex, coveredIndex)
    }

    /// The live twin of migration v10's hoist: embedded art belongs to the album
    /// row, so the album grid and the Debut mosaic can read it without loading a
    /// track, and the queue's `SELECT` never touches a BLOB.
    func testInsertTracksHoistsEmbeddedArtworkIntoAlbumInfo() throws {
        let title = "\(namespace) hoisted"
        let artwork = Data(repeating: 0xCD, count: 8_192)
        let track = makeTrack(album: title, artist: namespace, artwork: artwork)
        try db.insertTracks([track])

        XCTAssertEqual(try db.fetchAlbumArtwork(title: title, artist: namespace), artwork)
        XCTAssertNil(try XCTUnwrap(db.fetchTrack(byRelativePath: track.fileURL)).artworkData)
    }

    private func nonASCIIAlbums() -> [(title: String, artist: String)] {
        [
            (title: "\(namespace) Ágætis byrjun", artist: "Sigur Rós"),
            (title: "\(namespace) A\u{301}gætis byrjun", artist: "Sigur Ro\u{301}s"),
            (title: "\(namespace) MOTÖRHEAD\u{2009}", artist: "Motörhead"),
        ]
    }

    /// Every combination of the columns the due clause reads, so a change to
    /// either the SQL or the Swift predicate has to move both to stay green.
    private func states(for scope: EnrichmentScope) -> [EnrichmentRecord] {
        let statuses: [EnrichmentStatus] = [.pending, .satisfied, .exhausted, .partial]
        let versions = [scope.currentVersion - 1, scope.currentVersion]
        let fieldSets: [EnrichmentFields] = [[], .genre, EnrichmentFields.required(for: scope)]
        let eligibility: [Date?] = [nil, now.addingTimeInterval(-3_600), now.addingTimeInterval(3_600)]

        return statuses.flatMap { status in
            versions.flatMap { version in
                fieldSets.flatMap { fields in
                    eligibility.map { nextEligibleAt in
                        EnrichmentRecord(
                            scope: scope,
                            key: "",
                            version: version,
                            status: status,
                            fields: fields,
                            attempts: 1,
                            lastAttemptAt: now.addingTimeInterval(-86_400),
                            nextEligibleAt: nextEligibleAt
                        )
                    }
                }
            }
        }
    }

    private func makeTrack(
        album: String,
        artist: String,
        directory: String? = nil,
        aiAnalyzed: Bool = true,
        artwork: Data? = nil
    ) -> TrackRecord {
        let folder = directory ?? "\(namespace)/\(album)"
        let path = "\(folder)/\(insertedPaths.count).flac"
        insertedPaths.append(path)
        return TrackRecord(
            id: nil,
            fileURL: path,
            title: "Track \(insertedPaths.count)",
            artist: artist,
            albumTitle: album,
            trackNumber: 1,
            duration: 210,
            artworkData: artwork,
            lastFMArtworkURL: nil,
            musicBrainzID: nil,
            albumMusicBrainzID: nil,
            dateAdded: now,
            lastPlayed: nil,
            playCount: 0,
            aiAnalyzed: aiAnalyzed,
            analysisAttemptedAt: nil,
            codec: "flac",
            bitDepth: 16,
            sampleRate: 44_100,
            channels: 2
        )
    }
}
