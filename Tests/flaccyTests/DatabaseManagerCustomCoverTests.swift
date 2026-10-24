import FlaccyCore
import XCTest
@testable import flaccy

/// A chosen cover has to outlast everything else that writes `albumInfo`. Each
/// of these paths fails silently — the person's cover just quietly reverts — so
/// they are asserted against a real database.
nonisolated final class DatabaseManagerCustomCoverTests: XCTestCase {

    private var directory: URL!
    private var manager: DatabaseManager!
    private let custom = Data(repeating: 0xC1, count: 2_048)
    private let embedded = Data(repeating: 0xE5, count: 4_096)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-custom-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testACustomCoverOutranksEmbeddedAndDownloadedArtwork() throws {
        try insert(path: "A/1.flac", artist: "X", album: "Album", artwork: embedded)
        XCTAssertEqual(try manager.fetchAlbumArtwork(title: "Album", artist: "X"), embedded)

        try manager.saveCustomCover(custom, forKeys: [("Album", "X")])
        XCTAssertEqual(try manager.fetchAlbumArtwork(title: "Album", artist: "X"), custom)
        XCTAssertTrue(manager.hasCustomCover(forKeys: [("Album", "X")]))
    }

    func testResettingGivesTheOriginalBack() throws {
        try insert(path: "A/1.flac", artist: "X", album: "Album", artwork: embedded)
        try manager.saveCustomCover(custom, forKeys: [("Album", "X")])
        try manager.clearCustomCover(forKeys: [("Album", "X")])

        XCTAssertEqual(try manager.fetchAlbumArtwork(title: "Album", artist: "X"), embedded)
        XCTAssertFalse(manager.hasCustomCover(forKeys: [("Album", "X")]))
    }

    func testRescanningAndEnrichmentNeverOverwriteIt() throws {
        try insert(path: "A/1.flac", artist: "X", album: "Album", artwork: embedded)
        try manager.saveCustomCover(custom, forKeys: [("Album", "X")])

        try insert(path: "A/2.flac", artist: "X", album: "Album", artwork: Data(repeating: 0x77, count: 512))
        try manager.saveAlbumCoverArtIfMissing(title: "Album", artist: "X", data: Data(repeating: 0x55, count: 512))
        try manager.applyAlbumEnrichment(
            title: "Album", artist: "X", coverArtURL: "https://example.com/c.jpg",
            coverArtData: Data(repeating: 0x66, count: 512), musicBrainzID: "mbid", year: "2001", genre: "Rock",
            record: EnrichmentRecord(scope: .album, key: EnrichmentKey.album(title: "Album", artist: "X"))
        )
        XCTAssertEqual(try manager.fetchAlbumArtwork(title: "Album", artist: "X"), custom)
    }

    func testACreditedReleaseKeepsTheCoverChosenForIt() throws {
        for (index, artist) in ["Composer A", "Composer B"].enumerated() {
            try insert(path: "Score/\(index).flac", artist: artist, album: "Score", artwork: embedded)
        }
        let keys: [(title: String, artist: String)] = [
            ("Score", AlbumCredit.variousArtists), ("Score", "Composer A"), ("Score", "Composer B"),
        ]
        try manager.saveCustomCover(custom, forKeys: keys)

        try manager.resolveAlbumCredits()
        try manager.resolveAlbumCredits()

        for key in keys {
            XCTAssertEqual(try manager.fetchAlbumArtwork(title: key.title, artist: key.artist), custom, key.artist)
        }
    }

    func testMergingAnEditionIntoItsCanonicalAlbumCarriesTheChosenCover() throws {
        try insert(path: "A/1.flac", artist: "X", album: "Album", artwork: embedded)
        try insert(path: "B/1.flac", artist: "X", album: "Album (Deluxe)", artwork: embedded)
        try manager.saveCustomCover(custom, forKeys: [("Album (Deluxe)", "X")])

        try manager.applyHygiene(
            retitles: [AlbumRetitle(fromTitle: "Album (Deluxe)", fromArtist: "X", toTitle: "Album", toArtist: "X")],
            keeperUpdates: [],
            albumInfoMerges: [AlbumInfoMerge(
                canonicalTitle: "Album", canonicalArtist: "X",
                variants: [LibraryHygiene.AlbumVariant(title: "Album (Deluxe)", artist: "X")]
            )],
            loserRelativePaths: []
        )
        XCTAssertEqual(try manager.fetchAlbumArtwork(title: "Album", artist: "X"), custom)
    }

    func testTheCoverIsStoredUnderEveryKeyAndClearedFromEveryKey() throws {
        let keys: [(title: String, artist: String)] = [("Album", "X"), ("Album", "Y")]
        try manager.saveCustomCover(custom, forKeys: keys)
        for key in keys {
            XCTAssertEqual(try manager.fetchAlbumArtwork(title: key.title, artist: key.artist), custom)
        }
        try manager.clearCustomCover(forKeys: keys)
        for key in keys {
            XCTAssertNil(try manager.fetchAlbumArtwork(title: key.title, artist: key.artist))
        }
    }

    private func insert(path: String, artist: String, album: String, artwork: Data?) throws {
        try manager.insertTracks([
            TrackRecord(
                fileURL: path, title: path, artist: artist, albumTitle: album, albumArtist: nil,
                trackNumber: 1, duration: 100, artworkData: artwork, lastFMArtworkURL: nil,
                musicBrainzID: nil, albumMusicBrainzID: nil, dateAdded: Date(), lastPlayed: nil,
                playCount: 0, aiAnalyzed: false, analysisAttemptedAt: nil, codec: "FLAC",
                bitDepth: 16, sampleRate: 44100, channels: 2
            )
        ])
    }
}
