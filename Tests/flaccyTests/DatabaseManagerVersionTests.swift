import FlaccyCore
import GRDB
import XCTest
@testable import flaccy

/// The SQL half of the track-versions proof. `TrackRevision` decides what a scan
/// concludes; these pin what the database does with the verdict: a revised song
/// keeps its row, its playlist place and its plays, and a row the AI has already
/// cleaned keeps its cleaned tags while the file facts still follow the file.
nonisolated final class DatabaseManagerVersionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testANewRowStartsAtRevisionOneWithoutASignature() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac")

        let versions = try manager.fetchStoredVersions()
        XCTAssertEqual(versions["a.flac"], StoredVersion(signature: nil, fingerprint: nil, revision: 1, revisedAt: nil))
    }

    func testStoringAVersionRoundTripsEveryField() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac")
        let revisedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = StoredVersion(
            signature: FileSignature(size: 123, modifiedMilliseconds: 1_699_999_999_123),
            fingerprint: "flac:abc",
            revision: 4,
            revisedAt: revisedAt
        )

        try manager.updateVersion(relativePath: "a.flac", stored)

        XCTAssertEqual(try manager.fetchStoredVersion(relativePath: "a.flac"), stored)
        let record = try XCTUnwrap(manager.fetchTrack(byRelativePath: "a.flac"))
        XCTAssertEqual(record.revision, 4)
        XCTAssertEqual(record.fileSize, 123)
        XCTAssertEqual(record.fileModifiedMs, 1_699_999_999_123)
    }

    func testRefreshingMetadataKeepsTheRowItsPlaylistPlaceAndItsPlays() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac", title: "Old Title")
        try insert(manager, path: "b.flac", title: "Other")
        let playlist = try manager.createPlaylist(name: "Mix")
        let playlistID = try XCTUnwrap(playlist.id)
        try manager.addTracksToPlaylist(playlistId: playlistID, trackFileURLs: ["b.flac", "a.flac"])
        try manager.setPlayCount(relativePath: "a.flac", count: 9)
        try manager.setLoved(fileURL: "a.flac", loved: true, pendingOp: nil)
        let before = try XCTUnwrap(manager.fetchTrack(byRelativePath: "a.flac"))

        let revised = StoredVersion(
            signature: FileSignature(size: 9, modifiedMilliseconds: 9), fingerprint: "sha256:new", revision: 2, revisedAt: Date()
        )
        let found = try manager.refreshMetadata(
            relativePath: "a.flac",
            with: refresh(title: "New Title", duration: 210, codec: "WAV"),
            storing: revised
        )

        XCTAssertTrue(found)
        let after = try XCTUnwrap(manager.fetchTrack(byRelativePath: "a.flac"))
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.title, "New Title")
        XCTAssertEqual(after.duration, 210)
        XCTAssertEqual(after.codec, "WAV")
        XCTAssertEqual(after.playCount, 9)
        XCTAssertTrue(after.loved)
        XCTAssertEqual(after.revision, 2)
        XCTAssertEqual(try manager.fetchPlaylistTracks(playlistId: playlistID).map(\.trackFileURL), ["b.flac", "a.flac"])
    }

    func testARowTheAIHasCleanedKeepsItsTagsButFollowsTheFile() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac", title: "Cleaned Title", aiAnalyzed: true)

        try manager.refreshMetadata(relativePath: "a.flac", with: refresh(title: "Raw Tag Title", duration: 99, codec: "FLAC"))

        let after = try XCTUnwrap(manager.fetchTrack(byRelativePath: "a.flac"))
        XCTAssertEqual(after.title, "Cleaned Title")
        XCTAssertEqual(after.duration, 99)
    }

    func testRefreshingAMissingPathChangesNothing() throws {
        let manager = try makeManager()
        XCTAssertFalse(try manager.refreshMetadata(relativePath: "gone.flac", with: refresh(title: "x", duration: 1, codec: nil)))
    }

    func testEmbeddedArtOfARefreshedTrackLandsOnItsAlbum() throws {
        let manager = try makeManager()
        try insert(manager, path: "a.flac", title: "One", album: "Album")

        try manager.refreshMetadata(
            relativePath: "a.flac",
            with: refresh(title: "One", duration: 1, codec: "FLAC", album: "Album", artwork: Data([1, 2, 3]))
        )

        XCTAssertTrue(try manager.fetchAlbumInfoStatus(title: "Album", artist: "Artist").hasCover)
    }

    func testPreviousVersionsRoundTripAndExpireAfterThirtyDays() throws {
        let manager = try makeManager()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = PreviousVersionRecord(trackFileURL: "fresh.flac", storedPath: "fresh.flac", movedAt: now.addingTimeInterval(-29 * 86_400))
        let stale = PreviousVersionRecord(trackFileURL: "stale.flac", storedPath: "stale.flac", movedAt: now.addingTimeInterval(-31 * 86_400))
        try manager.upsertPreviousVersion(fresh)
        try manager.upsertPreviousVersion(stale)

        XCTAssertEqual(try manager.fetchPreviousVersion(trackFileURL: "fresh.flac"), fresh)
        XCTAssertEqual(try manager.fetchExpiredPreviousVersions(now: now), [stale])

        let restamped = PreviousVersionRecord(trackFileURL: "stale.flac", storedPath: "stale.flac", movedAt: now)
        try manager.upsertPreviousVersion(restamped)
        XCTAssertEqual(try manager.fetchExpiredPreviousVersions(now: now), [])

        try manager.deletePreviousVersion(trackFileURL: "fresh.flac")
        XCTAssertFalse(manager.hasPreviousVersion(trackFileURL: "fresh.flac"))
    }

    private func makeManager() throws -> DatabaseManager {
        try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    private func refresh(
        title: String, duration: Double, codec: String?, album: String = "Album", artwork: Data? = nil
    ) -> TrackMetadataRefresh {
        TrackMetadataRefresh(
            title: title,
            artist: "Artist",
            albumTitle: album,
            albumArtist: nil,
            trackNumber: 1,
            duration: duration,
            artworkData: artwork,
            codec: codec,
            bitDepth: 16,
            sampleRate: 44_100,
            channels: 2
        )
    }

    private func insert(
        _ manager: DatabaseManager, path: String, title: String = "Title", album: String = "Album", aiAnalyzed: Bool = false
    ) throws {
        try manager.insertTracks([
            TrackRecord(
                fileURL: path,
                title: title,
                artist: "Artist",
                albumTitle: album,
                trackNumber: 1,
                duration: 100,
                dateAdded: Date(),
                playCount: 0,
                aiAnalyzed: aiAnalyzed,
                codec: "FLAC",
                bitDepth: 16,
                sampleRate: 44_100,
                channels: 2
            )
        ])
    }
}
