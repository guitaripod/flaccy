import XCTest
@testable import FlaccyCore

final class TagCompletenessTests: XCTestCase {

    private func isComplete(
        title: String? = "Pink Moon", artist: String? = "Nick Drake", albumTitle: String? = "Pink Moon", trackNumber: Int = 1
    ) -> Bool {
        TagCompleteness.isComplete(title: title, artist: artist, albumTitle: albumTitle, trackNumber: trackNumber)
    }

    func testAFileWithAllFourTagsIsComplete() {
        XCTAssertTrue(isComplete())
        XCTAssertTrue(isComplete(title: "  Schism ", artist: "Tool", albumTitle: "Lateralus", trackNumber: 5))
        XCTAssertTrue(isComplete(title: "夜に駆ける", artist: "YOASOBI", albumTitle: "THE BOOK", trackNumber: 3))
    }

    func testAMissingOrBlankTagIsNotComplete() {
        XCTAssertFalse(isComplete(title: nil))
        XCTAssertFalse(isComplete(artist: nil))
        XCTAssertFalse(isComplete(albumTitle: nil))
        XCTAssertFalse(isComplete(title: ""))
        XCTAssertFalse(isComplete(artist: "   "))
        XCTAssertFalse(isComplete(albumTitle: "\n"))
    }

    func testAFileWithoutATrackNumberIsNotComplete() {
        XCTAssertFalse(isComplete(trackNumber: 0))
        XCTAssertFalse(isComplete(trackNumber: -1))
    }

    func testARippersPlaceholderIsNotATag() {
        XCTAssertFalse(isComplete(artist: "Unknown Artist"))
        XCTAssertFalse(isComplete(artist: " unknown artist "))
        XCTAssertFalse(isComplete(albumTitle: "Unknown Album"))
        XCTAssertFalse(isComplete(title: "Track 03"))
        XCTAssertFalse(isComplete(title: "track3"))
        XCTAssertFalse(isComplete(title: "Track_07"))
        XCTAssertFalse(isComplete(title: "Track - 11"))
        XCTAssertFalse(isComplete(title: "Audiotrack 12"))
        XCTAssertFalse(isComplete(title: "AudioTrack 01"))
    }

    func testARealTitleThatLooksLikeAPlaceholderStays() {
        XCTAssertTrue(isComplete(title: "Track"))
        XCTAssertTrue(isComplete(title: "Track 3 (Demo)"))
        XCTAssertTrue(isComplete(title: "Tracks of My Tears"))
        XCTAssertTrue(isComplete(title: "Audio"))
        XCTAssertTrue(isComplete(title: "Untitled"))
        XCTAssertTrue(isComplete(title: "Unknown"))
        XCTAssertTrue(isComplete(title: "7"))
        XCTAssertTrue(isComplete(artist: "Unknown Mortal Orchestra"))
        XCTAssertTrue(isComplete(artist: "Various Artists"))
        XCTAssertTrue(isComplete(albumTitle: "Unknown Pleasures"))
    }
}
