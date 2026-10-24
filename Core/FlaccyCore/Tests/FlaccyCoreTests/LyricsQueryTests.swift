import XCTest
@testable import FlaccyCore

final class LyricsQueryTests: XCTestCase {

    func testEditionDecorationIsRemovedFromATitle() {
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Remastered 2011)"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song - 2011 Remaster"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song [Deluxe Edition]"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Don't Stop Me Now - Remastered"), "Don't Stop Me Now")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Remastered) (Live)"), "Song (Live)")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Mono)  "), "Song")
    }

    func testAFeaturingClauseIsCut() {
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (feat. Someone)"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song feat. Someone"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (ft. A & B) [Explicit]"), "Song")
    }

    func testDifferentRecordingsAndPlainTitlesAreUntouched() {
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Live)"), "Song (Live)")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Acoustic Version)"), "Song (Acoustic Version)")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Radio Edit)"), "Song (Radio Edit)")
        XCTAssertEqual(LyricsQuery.cleanTitle("Stereo Love"), "Stereo Love")
        XCTAssertEqual(LyricsQuery.cleanTitle("Clean - Part 2"), "Clean - Part 2")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (Remix"), "Song (Remix")
    }

    func testATitleThatWouldVanishIsKept() {
        XCTAssertEqual(LyricsQuery.cleanTitle("(Remastered)"), "(Remastered)")
        XCTAssertEqual(LyricsQuery.cleanTitle(""), "")
    }

    func testTheLeadArtistIsTheFirstCredit() {
        XCTAssertEqual(LyricsQuery.leadArtist("Artist A feat. B"), "Artist A")
        XCTAssertEqual(LyricsQuery.leadArtist("A; B"), "A")
        XCTAssertEqual(LyricsQuery.leadArtist("A / B"), "A")
        XCTAssertEqual(LyricsQuery.leadArtist("A (ft. B)"), "A")
        XCTAssertEqual(LyricsQuery.leadArtist("Simon & Garfunkel"), "Simon & Garfunkel")
        XCTAssertEqual(LyricsQuery.leadArtist("AC/DC"), "AC/DC")
        XCTAssertEqual(LyricsQuery.leadArtist("Tyler, The Creator"), "Tyler, The Creator")
        XCTAssertEqual(LyricsQuery.leadArtist("; B"), "; B")
    }

    func testEditionKeywordsListIsComplete() {
        XCTAssertEqual(LyricsQuery.editionKeywords.count, 17)
    }
}
