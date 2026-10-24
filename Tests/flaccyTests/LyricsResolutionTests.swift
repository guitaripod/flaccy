import FlaccyCore
import XCTest
@testable import flaccy

/// The rules behind the lyrics pipeline that need neither a network nor a
/// player: which cached rows are still served, how a stored answer becomes a
/// document, how the listener's timing correction moves the clock, and that a
/// correction survives the lyrics being fetched again. The Rust client proves
/// the same rules in `linux/src/lyrics.rs`.
nonisolated final class LyricsResolutionTests: XCTestCase {

    private static let lyricsfile = """
    version: '1.0'
    metadata:
      title: t
      artist: a
    lines:
    - text: Hello
      start_ms: 1000
      end_ms: 3000
      words:
      - text: 'Hel'
        start_ms: 1000
        end_ms: 2000
      - text: lo
        start_ms: 2000
        end_ms: 3000

    """

    private func record(
        synced: String?, plain: String? = nil, lyricsfile: String? = nil,
        revision: Int, fetchedAt: Date? = Date()
    ) -> LyricsRecord {
        LyricsRecord(
            id: nil, trackTitle: "Song", artist: "Artist", syncedLyrics: synced, plainLyrics: plain,
            instrumental: false, fetchedAt: fetchedAt, lyricsfile: lyricsfile, offsetMs: 0, revision: revision
        )
    }

    func testAReadableLyricsfileBeatsTheLRCText() {
        let document = LyricsResolution.document(
            synced: "[00:05.00]other", plain: nil, lyricsfile: Self.lyricsfile, instrumental: false)
        XCTAssertTrue(document.hasWordSync)
        XCTAssertEqual(document.lines.last?.text, "Hello")
    }

    func testAnUnreadableLyricsfileFallsBackToTheLRCText() {
        let document = LyricsResolution.document(
            synced: "[00:05.00]other", plain: nil, lyricsfile: "not: [yaml", instrumental: false)
        XCTAssertFalse(document.hasWordSync)
        XCTAssertEqual(document.lines.last?.text, "other")
    }

    func testPlainLyricsRideAlongWithSyncedOnes() {
        let document = LyricsResolution.document(
            synced: "[00:05.00]x", plain: "x\ny", lyricsfile: nil, instrumental: false)
        XCTAssertEqual(document.plain, "x\ny")
    }

    func testInstrumentalWinsOverEverything() {
        let document = LyricsResolution.document(
            synced: "[00:05.00]x", plain: "x", lyricsfile: Self.lyricsfile, instrumental: true)
        XCTAssertTrue(document.instrumental)
        XCTAssertTrue(document.lines.isEmpty)
    }

    func testContentFromAnOlderRevisionIsAskedForAgain() {
        XCTAssertFalse(LyricsResolution.isCurrent(record(synced: "[00:01.00]x", revision: 0)))
        XCTAssertTrue(LyricsResolution.isCurrent(record(synced: "[00:01.00]x", revision: LyricsResolution.revision)))
    }

    func testAMissStandsForThirtyDaysWhateverItsRevision() {
        let now = Date()
        let fresh = record(synced: nil, revision: 0, fetchedAt: now.addingTimeInterval(-10 * 86_400))
        let old = record(synced: nil, revision: 0, fetchedAt: now.addingTimeInterval(-31 * 86_400))
        let undated = record(synced: nil, revision: 0, fetchedAt: nil)
        XCTAssertTrue(LyricsResolution.isCurrent(fresh, now: now))
        XCTAssertFalse(LyricsResolution.isCurrent(old, now: now))
        XCTAssertFalse(LyricsResolution.isCurrent(undated, now: now))
    }

    func testALocalFileWithStampsStaysSynchronizedWithItsWordTags() {
        let local = LyricsResolution.classify("[00:05.00]<00:05.00>Hi <00:05.50>there")
        XCTAssertNotNil(local.synced)
        XCTAssertTrue(LyricsResolution.document(
            synced: local.synced, plain: nil, lyricsfile: nil, instrumental: false).hasWordSync)
        let unsynced = LyricsResolution.classify("just words\nno stamps")
        XCTAssertNil(unsynced.synced)
        XCTAssertEqual(unsynced.plain, "just words\nno stamps")
    }

    func testTheOffsetMovesTheSongTimeOppositeToThePosition() {
        let later = Lyrics(document: LyricsParser.parseLRC("[00:10.00]a\n[00:20.00]b"), offsetMs: 500)
        XCTAssertNil(later.text(at: 10.4))
        XCTAssertEqual(later.text(at: 10.6), "a")
        let earlier = Lyrics(document: later.document, offsetMs: -500)
        XCTAssertEqual(earlier.text(at: 9.6), "a")
    }

    func testQueryValuesNeverReachTheServerAsSyntax() {
        XCTAssertEqual(LyricsResolution.urlEncode("Simon & Garfunkel"), "Simon%20%26%20Garfunkel")
        XCTAssertEqual(LyricsResolution.urlEncode("a+b=c"), "a%2Bb%3Dc")
        XCTAssertEqual(LyricsResolution.urlEncode("Plain-text_1.0~"), "Plain-text_1.0~")
    }

    func testACorrectionSurvivesTheLyricsBeingFetchedAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)

        try db.saveLyrics(record(synced: "[00:01.00]x", revision: 0))
        try db.saveLyricsOffset(trackTitle: "Song", artist: "Artist", offsetMs: 300)
        let cached = try XCTUnwrap(try db.fetchLyrics(trackTitle: "Song", artist: "Artist"))
        XCTAssertEqual(cached.offsetMs, 300)
        XCTAssertEqual(cached.revision, 0)

        var refreshed = record(synced: "[00:01.00]y", lyricsfile: Self.lyricsfile, revision: LyricsResolution.revision)
        refreshed.id = cached.id
        refreshed.offsetMs = cached.offsetMs
        try db.saveLyrics(refreshed)
        let stored = try XCTUnwrap(try db.fetchLyrics(trackTitle: "Song", artist: "Artist"))
        XCTAssertEqual(stored.offsetMs, 300)
        XCTAssertEqual(stored.revision, LyricsResolution.revision)
        XCTAssertEqual(stored.lyricsfile, Self.lyricsfile)

        try db.setLyricsRevision(trackTitle: "Song", artist: "Artist", revision: 5)
        XCTAssertEqual(try db.fetchLyrics(trackTitle: "Song", artist: "Artist")?.revision, 5)
    }
}
