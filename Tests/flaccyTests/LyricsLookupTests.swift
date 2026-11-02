import FlaccyCore
import XCTest
@testable import flaccy

/// How the questions put to lrclib add up to one answer, driven by scripted
/// replies instead of a network. The Rust client proves the same rules in
/// `linux/src/lyrics.rs`.
nonisolated final class LyricsLookupTests: XCTestCase {

    private let found = LyricsService.Remote.found(
        LyricsService.Fetched(synced: "[00:01.00]words", plain: nil, lyricsfile: nil, instrumental: false)
    )

    private func run(
        track: String = "Song", answers: [LyricsService.Remote]
    ) async -> (outcome: String, asked: Int) {
        var asked = 0
        let remote = await LyricsService.lookup(track: track, artist: "Artist", album: "Album") { _ in
            defer { asked += 1 }
            return asked < answers.count ? answers[asked] : .missing
        }
        return (Self.describe(remote), asked)
    }

    private static func describe(_ remote: LyricsService.Remote) -> String {
        switch remote {
        case .found: return "found"
        case .missing: return "missing"
        case .failed(let failure): return "failed \(failure)"
        }
    }

    func testABusyAnswerLetsThePlainerQuestionFindTheSong() async {
        let result = await run(answers: [.failed(.server(503)), found])
        XCTAssertEqual(result.outcome, "found")
        XCTAssertEqual(result.asked, 2)
    }

    func testQuestionsThatWereAllBusyMakeTheLookupAFailureNotAMiss() async {
        let result = await run(answers: [.failed(.server(503)), .missing, .missing])
        XCTAssertEqual(result.outcome, "failed server(503)")
        XCTAssertEqual(result.asked, 3)
    }

    func testALookupWhereEveryQuestionWasAnsweredEmptyIsAMiss() async {
        let result = await run(answers: [])
        XCTAssertEqual(result.outcome, "missing")
        XCTAssertEqual(result.asked, 3)
    }

    func testAServerThatIsNotAnsweringEndsTheLookupAtOnce() async {
        let failures: [LyricsFailure] = [.unreachable, .timedOut, .busy, .server(502), .rejected(403)]
        for failure in failures {
            let result = await run(answers: [.failed(failure)])
            XCTAssertEqual(result.outcome, "failed \(failure)")
            XCTAssertEqual(result.asked, 1, "\(failure)")
        }
    }

    func testADecoratedTitleAddsAQuestionWithTheEditionRemoved() async {
        let result = await run(track: "Song (Remastered 2011)", answers: [])
        XCTAssertEqual(result.outcome, "missing")
        XCTAssertEqual(result.asked, 4)
    }
}
