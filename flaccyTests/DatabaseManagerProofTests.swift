import FlaccyCore
import XCTest
@testable import flaccy

/// The paywall's proof card is a handful of COUNT statements, and each one
/// carries a predicate that can drift silently: a lyrics miss is a row with
/// both columns NULL, a found cover only counts while its album still has a
/// track, and lossless is `Track.isLossless` rewritten in SQL. Each test opens
/// its own database so the totals are exact rather than deltas against
/// whatever the shared library happens to hold.
nonisolated final class DatabaseManagerProofTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!
    private var insertedPaths = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
        insertedPaths = 0
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testEmptyLibraryReportsZeros() throws {
        let totals = try db.libraryTotals()
        XCTAssertEqual(totals.tracks, 0)
        XCTAssertEqual(totals.lossless, 0)
        XCTAssertEqual(totals.seconds, 0)
        XCTAssertEqual(try db.scrobbleCount(submittedOnly: false), 0)
        XCTAssertEqual(try db.scrobbleCount(submittedOnly: true), 0)
        XCTAssertEqual(try db.lyricsMatchedCount(), 0)
        XCTAssertEqual(try db.coversResolvedCount(), 0)
        XCTAssertEqual(try db.aiReviewedTrackCount(), 0)
    }

    func testLibraryTotalsCountsLosslessCodecsCaseInsensitivelyAndNotLossy() throws {
        let codecs: [String?] = ["flac", "ALAC", "Wav", "aiff", "MP3", "aac", "Opus", nil]
        try db.insertTracks(codecs.map { makeTrack(codec: $0) })

        let totals = try db.libraryTotals()
        XCTAssertEqual(totals.tracks, codecs.count)
        XCTAssertEqual(totals.lossless, 4)
    }

    func testLibraryTotalsAgreeWithTrackIsLossless() throws {
        let codecs: [String?] = ["FLAC", "alac", "WAV", "AiFf", "mp3", "AAC", "", nil]
        let records = codecs.map { makeTrack(codec: $0) }
        try db.insertTracks(records)

        let expected = records.count { Track.from(record: $0, artwork: nil).isLossless }
        XCTAssertEqual(try db.libraryTotals().lossless, expected)
    }

    func testLibraryTotalsSumsDurations() throws {
        let durations: [Double] = [210.5, 89.25, 0, 3_600]
        try db.insertTracks(durations.map { makeTrack(duration: $0) })

        XCTAssertEqual(try db.libraryTotals().seconds, durations.reduce(0, +), accuracy: 0.0001)
    }

    func testScrobbleCountDistinguishesSubmittedFromAllPlays() throws {
        try db.insertScrobble(makeScrobble(submitted: true))
        try db.insertScrobble(makeScrobble(submitted: false))
        try db.insertScrobble(makeScrobble(submitted: false))

        XCTAssertEqual(try db.scrobbleCount(submittedOnly: true), 1)
        XCTAssertEqual(try db.scrobbleCount(submittedOnly: false), 3)

        try db.retirePendingScrobbles(olderThan: .distantFuture)
        XCTAssertEqual(try db.scrobbleCount(submittedOnly: true), 3)
        XCTAssertEqual(try db.scrobbleCount(submittedOnly: false), 3)
    }

    func testLyricsMatchedCountsSyncedRowsOnly() throws {
        try db.saveLyrics(makeLyrics(title: "Synced", synced: "[00:01.00] Hello", plain: "Hello"))
        try db.saveLyrics(makeLyrics(title: "Synced only", synced: "[00:01.00] Hello", plain: nil))
        try db.saveLyrics(makeLyrics(title: "Plain only", synced: nil, plain: "Hello"))
        try db.saveLyrics(makeLyrics(title: "Instrumental", synced: nil, plain: nil, instrumental: true))
        try db.saveLyrics(makeLyrics(title: "Miss", synced: nil, plain: nil))

        XCTAssertEqual(try db.lyricsMatchedCount(), 2)
    }

    /// A remembered lrclib miss is exactly what `LyricsService` writes when
    /// nothing was found: both lyrics columns NULL, not instrumental, stamped.
    func testLyricsMissRowIsNotCounted() throws {
        try db.saveLyrics(makeLyrics(title: "Miss", synced: nil, plain: nil))
        XCTAssertNotNil(try db.fetchLyrics(trackTitle: "Miss", artist: "Artist"))
        XCTAssertEqual(try db.lyricsMatchedCount(), 0)
    }

    func testCoversResolvedRequiresURLAndAnAlbumStillInTheLibrary() throws {
        try db.insertTracks([
            makeTrack(album: "Resolved", artist: "Artist"),
            makeTrack(album: "Embedded only", artist: "Artist", artwork: Data(repeating: 0xAB, count: 2_048)),
            makeTrack(album: "Unresolved", artist: "Artist"),
            makeTrack(album: "Same title", artist: "Someone Else"),
        ])
        try db.applyAlbumEnrichment(
            title: "Resolved",
            artist: "Artist",
            coverArtURL: "https://example.com/resolved.jpg",
            coverArtData: nil,
            musicBrainzID: nil,
            year: nil,
            genre: nil,
            record: EnrichmentRecord(scope: .album, key: EnrichmentKey.album(title: "Resolved", artist: "Artist"))
        )
        try setCoverArtURL("https://example.com/orphan.jpg", title: "Orphan", artist: "Artist")
        try setCoverArtURL("https://example.com/other.jpg", title: "Same title", artist: "Artist")

        XCTAssertNotNil(try db.fetchAlbumArtwork(title: "Embedded only", artist: "Artist"))
        XCTAssertNil(try XCTUnwrap(db.fetchAlbumInfo(title: "Embedded only", artist: "Artist")).coverArtURL)
        XCTAssertEqual(try db.coversResolvedCount(), 1)
    }

    func testCoversResolvedDropsAnAlbumOnceItsTracksAreGone() throws {
        let track = makeTrack(album: "Leaving", artist: "Artist")
        try db.insertTracks([track])
        try setCoverArtURL("https://example.com/leaving.jpg", title: "Leaving", artist: "Artist")
        XCTAssertEqual(try db.coversResolvedCount(), 1)

        try db.deleteTracksNotIn(relativePaths: [])
        XCTAssertNotNil(try db.fetchAlbumInfo(title: "Leaving", artist: "Artist"))
        XCTAssertEqual(try db.coversResolvedCount(), 0)
    }

    func testAIReviewedCountsAnalyzedTracksOnly() throws {
        try db.insertTracks([
            makeTrack(aiAnalyzed: true),
            makeTrack(aiAnalyzed: true),
            makeTrack(aiAnalyzed: false),
        ])

        XCTAssertEqual(try db.aiReviewedTrackCount(), 2)
    }

    private func setCoverArtURL(_ url: String, title: String, artist: String) throws {
        var info = try db.fetchOrCreateAlbumInfo(title: title, artist: artist)
        info.coverArtURL = url
        try db.updateAlbumInfo(info)
    }

    private func makeTrack(
        album: String = "Album",
        artist: String = "Artist",
        codec: String? = "flac",
        duration: Double = 210,
        aiAnalyzed: Bool = false,
        artwork: Data? = nil
    ) -> TrackRecord {
        insertedPaths += 1
        return TrackRecord(
            id: nil,
            fileURL: "\(album)/\(insertedPaths).flac",
            title: "Track \(insertedPaths)",
            artist: artist,
            albumTitle: album,
            trackNumber: insertedPaths,
            duration: duration,
            artworkData: artwork,
            lastFMArtworkURL: nil,
            musicBrainzID: nil,
            albumMusicBrainzID: nil,
            dateAdded: Date(timeIntervalSince1970: 1_750_000_000),
            lastPlayed: nil,
            playCount: 0,
            aiAnalyzed: aiAnalyzed,
            analysisAttemptedAt: nil,
            codec: codec,
            bitDepth: 16,
            sampleRate: 44_100,
            channels: 2
        )
    }

    private func makeScrobble(submitted: Bool) -> ScrobbleRecord {
        ScrobbleRecord(
            id: nil,
            trackTitle: "Track",
            artist: "Artist",
            albumTitle: "Album",
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            duration: 210,
            submitted: submitted
        )
    }

    private func makeLyrics(title: String, synced: String?, plain: String?, instrumental: Bool = false) -> LyricsRecord {
        LyricsRecord(
            id: nil,
            trackTitle: title,
            artist: "Artist",
            syncedLyrics: synced,
            plainLyrics: plain,
            instrumental: instrumental,
            fetchedAt: Date()
        )
    }
}
