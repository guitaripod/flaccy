import FlaccyCore
import XCTest
@testable import FlaccyEngine

/// Which songs a background pass has to ask lrclib about: the database half of
/// `LyricsResolution.isCurrent`, with its 30 days and its revision 2.
final class LyricsWantTests: XCTestCase {

    private static let revision = 2
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-lyrics-want-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func addTrack(_ path: String, _ title: String, _ artist: String) throws {
        _ = try db.insertTrack(TrackRecord(
            fileURL: path, title: title, artist: artist, albumTitle: "Record", trackNumber: 1, duration: 200,
            dateAdded: now, playCount: 0, aiAnalyzed: false
        ))
    }

    private func store(
        _ title: String, _ artist: String, synced: String? = nil, plain: String? = nil,
        instrumental: Bool = false, fetchedAt: Date?, revision: Int = LyricsWantTests.revision
    ) throws {
        try db.saveLyrics(LyricsRecord(
            trackTitle: title, artist: artist, syncedLyrics: synced, plainLyrics: plain,
            instrumental: instrumental, fetchedAt: fetchedAt, revision: revision
        ))
    }

    private func wanted() throws -> [String] {
        try db.songsWantingLyrics(revision: Self.revision, missesFetchedBefore: now.addingTimeInterval(-30 * 86_400))
            .map(\.title).sorted()
    }

    func testASongWithNoRowIsWanted() throws {
        try addTrack("a.flac", "Alone", "Pilot")
        XCTAssertEqual(try wanted(), ["Alone"])
    }

    func testASongWithCurrentLyricsOrAnInstrumentalFlagIsNot() throws {
        try addTrack("a.flac", "Sung", "Pilot")
        try addTrack("b.flac", "Wordless", "Pilot")
        try store("Sung", "Pilot", synced: "[00:01.00]hello", fetchedAt: now)
        try store("Wordless", "Pilot", instrumental: true, fetchedAt: now)
        XCTAssertEqual(try wanted(), [])
    }

    func testContentFromBeforeTheCurrentRevisionIsAskedForAgain() throws {
        try addTrack("a.flac", "Old", "Pilot")
        try store("Old", "Pilot", plain: "words", fetchedAt: now, revision: 1)
        XCTAssertEqual(try wanted(), ["Old"])
    }

    func testAMissStandsForThirtyDaysAndAMissWithoutADateAlreadyExpired() throws {
        try addTrack("a.flac", "Fresh", "Pilot")
        try addTrack("b.flac", "Stale", "Pilot")
        try addTrack("c.flac", "Undated", "Pilot")
        try store("Fresh", "Pilot", fetchedAt: now.addingTimeInterval(-10 * 86_400))
        try store("Stale", "Pilot", fetchedAt: now.addingTimeInterval(-31 * 86_400))
        try store("Undated", "Pilot", fetchedAt: nil)
        XCTAssertEqual(try wanted(), ["Stale", "Undated"])
    }

    func testARowHoldingOnlyWhitespaceCountsAsAMiss() throws {
        try addTrack("a.flac", "Blank", "Pilot")
        try store("Blank", "Pilot", synced: "  \n", plain: " ", fetchedAt: now.addingTimeInterval(-40 * 86_400))
        XCTAssertEqual(try wanted(), ["Blank"])
    }

    func testFilesSharingATitleAndArtistAreListedOnce() throws {
        try addTrack("a.flac", "Twin", "Pilot")
        try addTrack("b.flac", "Twin", "Pilot")
        XCTAssertEqual(try wanted(), ["Twin"])
    }
}
