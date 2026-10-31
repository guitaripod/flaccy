import XCTest
@testable import FlaccyCore

final class ScanJournalReplayTests: XCTestCase {

    private func journal(_ entries: [(Character, String)]) -> String {
        entries.map { ScanJournalReplay.line($0.0, path: $0.1) }.joined()
    }

    func testAnEmptyJournalAccusesNothing() {
        let replay = ScanJournalReplay(journal: "")
        XCTAssertTrue(replay.suspects.isEmpty)
        XCTAssertTrue(replay.crashedAlone.isEmpty)
    }

    func testFilesReadToTheEndAreCleared() {
        let replay = ScanJournalReplay(journal: journal([
            ("R", "A/1.flac"), ("R", "A/2.flac"), ("D", "A/2.flac"), ("D", "A/1.flac"),
        ]))
        XCTAssertTrue(replay.suspects.isEmpty)
        XCTAssertTrue(replay.crashedAlone.isEmpty)
    }

    func testFilesInFlightWhenTheAppStoppedAreSuspects() {
        let replay = ScanJournalReplay(journal: journal([
            ("R", "A/1.flac"), ("R", "A/2.flac"), ("R", "A/3.flac"), ("D", "A/1.flac"),
        ]))
        XCTAssertEqual(replay.suspects, ["A/2.flac", "A/3.flac"])
        XCTAssertTrue(replay.crashedAlone.isEmpty)
    }

    func testAFileThatStoppedTheAppAloneIsNamed() {
        let replay = ScanJournalReplay(journal: journal([
            ("S", "A/2.flac"), ("D", "A/2.flac"), ("S", "A/3.flac"),
        ]))
        XCTAssertTrue(replay.suspects.isEmpty)
        XCTAssertEqual(replay.crashedAlone, ["A/3.flac"])
    }

    func testTheLatestMarkForAPathWins() {
        let replay = ScanJournalReplay(journal: journal([
            ("R", "A/1.flac"), ("S", "A/1.flac"),
        ]))
        XCTAssertEqual(replay.crashedAlone, ["A/1.flac"])
        XCTAssertTrue(replay.suspects.isEmpty)
    }

    func testPathsKeepTabsAndSpacesAfterTheMark() {
        let replay = ScanJournalReplay(journal: journal([("R", "Artist/01 \tOdd Name.flac")]))
        XCTAssertEqual(replay.suspects, ["Artist/01 \tOdd Name.flac"])
    }

    func testATornLastLineIsIgnored() {
        let text = journal([("R", "A/1.flac")]) + "R"
        let replay = ScanJournalReplay(journal: text)
        XCTAssertEqual(replay.suspects, ["A/1.flac"])
    }
}
