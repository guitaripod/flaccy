import FlaccyCore
import GRDB
import XCTest
@testable import flaccy

/// The Apple half of the album-credit proof.
///
/// `AlbumCredit` and its resolver are pinned in FlaccyCore against their Rust
/// mirrors, but two things live only here and only in SQL: the pass that writes
/// the settled credit back onto `tracks`, and the statement that lets a credited
/// release adopt the cover its member tracks hoisted. Both fail silently — a
/// soundtrack simply shows up as seven albums, or as one album with a blank
/// tile — so they are asserted against a real database rather than inferred.
nonisolated final class DatabaseManagerCreditTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-credits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFolderOfOneAlbumByManyArtistsResolvesToVariousArtists() throws {
        let manager = try makeManager()
        let composers = ["Gerard K. Marino", "Mike Reagan", "Cris Velasco", "Ron Fish", "Junkie XL"]
        for index in 0..<20 {
            try insert(
                manager, path: "God of War II/\(index).flac",
                artist: composers[index % composers.count], album: "God Of War II"
            )
        }

        XCTAssertEqual(try manager.resolveAlbumCredits(), 20)
        for credit in try credits(manager).values {
            XCTAssertEqual(credit, AlbumCredit.variousArtists)
        }
        XCTAssertEqual(try manager.resolveAlbumCredits(), 0, "a settled library rewrites nothing")
    }

    func testLooseFilesAtTheRootAreScopedByArtistNotByFolder() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac", artist: "Artist A", album: "Greatest Hits")
        try insert(manager, path: "b.flac", artist: "Artist B", album: "Greatest Hits")

        try manager.resolveAlbumCredits()
        let resolved = try credits(manager)
        XCTAssertEqual(resolved["a.flac"], "Artist A")
        XCTAssertEqual(resolved["b.flac"], "Artist B")
    }

    func testACoverThatArrivesAfterTheCreditsIsStillAdopted() throws {
        let manager = try makeManager()
        for (index, artist) in ["Composer A", "Composer B"].enumerated() {
            try insert(manager, path: "Late/\(index).flac", artist: artist, album: "Late")
        }
        XCTAssertEqual(try manager.resolveAlbumCredits(), 2)
        XCTAssertEqual(try manager.resolveAlbumCredits(), 0)

        try manager.saveAlbumCoverArtIfMissing(title: "Late", artist: "Composer A", data: Data([9, 9]))
        XCTAssertEqual(try manager.resolveAlbumCredits(), 0, "the credit did not change")

        let status = try manager.fetchAlbumInfoStatus(title: "Late", artist: AlbumCredit.variousArtists)
        XCTAssertTrue(status.hasCover, "the credited release adopted its member's cover")
    }

    private func makeManager() throws -> DatabaseManager {
        try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    private func insert(
        _ manager: DatabaseManager, path: String, artist: String, album: String
    ) throws {
        try manager.insertTracks([
            TrackRecord(
                fileURL: path,
                title: path,
                artist: artist,
                albumTitle: album,
                albumArtist: nil,
                trackNumber: 1,
                duration: 100,
                artworkData: nil,
                lastFMArtworkURL: nil,
                musicBrainzID: nil,
                albumMusicBrainzID: nil,
                dateAdded: Date(),
                lastPlayed: nil,
                playCount: 0,
                aiAnalyzed: false,
                analysisAttemptedAt: nil,
                codec: "FLAC",
                bitDepth: 16,
                sampleRate: 44100,
                channels: 2
            )
        ])
    }

    private func credits(_ manager: DatabaseManager) throws -> [String: String?] {
        Dictionary(
            uniqueKeysWithValues: try manager.fetchAllTracks().map { ($0.fileURL, $0.albumArtist) }
        )
    }
}
