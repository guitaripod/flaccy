import FlaccyCore
import XCTest
@testable import FlaccyEngine

/// The stored readings of what songs mean: one row per song, question and
/// language, replaced when asked again, aged the way `MeaningCache` reads it.
final class LyricMeaningDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-lyric-meaning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testNothingIsStoredUntilAReadingIsSaved() throws {
        XCTAssertNil(try db.lyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: MeaningCache.songScope, language: "en"))
    }

    func testAReadingIsKeptPerQuestionAndLanguageAndReplacedWhenAskedAgain() throws {
        let line = MeaningCache.lineScope("I don't care")
        try db.saveLyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: line, language: "en", body: "Apathy.")
        try db.saveLyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: line, language: "de", body: "Gleichgültigkeit.")
        try db.saveLyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: line, language: "en", body: "Not caring.")
        XCTAssertEqual(try db.lyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: line, language: "en")?.body, "Not caring.")
        XCTAssertEqual(try db.lyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: line, language: "de")?.body, "Gleichgültigkeit.")
        XCTAssertNil(try db.lyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: MeaningCache.songScope, language: "en"))
    }

    func testTheAgeIsCountedInDaysSoAStaleStoryIsAskedForAgain() throws {
        let old = Date().addingTimeInterval(-91 * 86_400)
        try db.saveLyricMeaning(
            trackTitle: "Breed", artist: "Nirvana", scope: MeaningCache.storyScope, language: "en", body: "{}", at: old)
        let stored = try XCTUnwrap(db.lyricMeaning(trackTitle: "Breed", artist: "Nirvana", scope: MeaningCache.storyScope, language: "en"))
        XCTAssertEqual(stored.ageDays, 91, accuracy: 0.01)
        XCTAssertFalse(MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: true, ageDays: stored.ageDays))
    }
}
