import XCTest
@testable import FlaccyCore

final class PaywallProofTests: XCTestCase {

    private func proof(
        trackCount: Int = 2_847,
        losslessTrackCount: Int = 2_619,
        totalDurationSeconds: Double = 1_656_000,
        plays: Int = 412,
        playsAreScrobbled: Bool = true,
        lyricsMatched: Int = 903,
        coversResolved: Int = 191,
        aiReviewedTracks: Int = 1_402
    ) -> PaywallProof {
        PaywallProof(
            trackCount: trackCount,
            losslessTrackCount: losslessTrackCount,
            totalDurationSeconds: totalDurationSeconds,
            plays: plays,
            playsAreScrobbled: playsAreScrobbled,
            lyricsMatched: lyricsMatched,
            coversResolved: coversResolved,
            aiReviewedTracks: aiReviewedTracks
        )
    }

    func testEmptyHasNoLibraryAndNoLines() {
        XCTAssertFalse(PaywallProof.empty.hasLibrary)
        XCTAssertEqual(PaywallProof.empty.listeningHours, 0)
        XCTAssertEqual(PaywallProof.empty.lines(), [])
        XCTAssertEqual(PaywallProof.empty.lines(limit: 5), [])
    }

    func testHasLibraryFollowsTheTrackCount() {
        XCTAssertTrue(proof(trackCount: 1).hasLibrary)
        XCTAssertFalse(proof(trackCount: 0).hasLibrary)
    }

    func testLinesFollowThePriorityOrder() {
        XCTAssertEqual(
            proof().lines(),
            [.lossless(tracks: 2_619, hours: 460), .scrobbled(412), .lyrics(903)]
        )
    }

    func testLimitBoundsTheLines() {
        let full: [PaywallProof.Line] = [
            .lossless(tracks: 2_619, hours: 460),
            .scrobbled(412),
            .lyrics(903),
            .covers(191),
            .aiReviewed(1_402),
        ]
        XCTAssertEqual(proof().lines(limit: 5), full)
        XCTAssertEqual(proof().lines(limit: 10), full)
        XCTAssertEqual(proof().lines(limit: 1), [.lossless(tracks: 2_619, hours: 460)])
        XCTAssertEqual(proof().lines(limit: 0), [])
        XCTAssertEqual(proof().lines(limit: -1), [])
    }

    func testDefaultLimitIsThree() {
        XCTAssertEqual(proof().lines().count, 3)
    }

    func testZerosAreSkippedAndLaterLinesMoveUp() {
        XCTAssertEqual(
            proof(losslessTrackCount: 0, plays: 0).lines(),
            [.lyrics(903), .covers(191), .aiReviewed(1_402)]
        )
        XCTAssertEqual(
            proof(lyricsMatched: 0, coversResolved: 0).lines(),
            [.lossless(tracks: 2_619, hours: 460), .scrobbled(412), .aiReviewed(1_402)]
        )
        XCTAssertEqual(
            proof(plays: 0, lyricsMatched: 0, coversResolved: 0, aiReviewedTracks: 0).lines(),
            [.lossless(tracks: 2_619, hours: 460)]
        )
    }

    func testALossyOnlyLibraryHasNoLosslessLine() {
        let lossy = proof(trackCount: 300, losslessTrackCount: 0, totalDurationSeconds: 72_000)
        XCTAssertTrue(lossy.hasLibrary)
        XCTAssertEqual(lossy.lines().first, .scrobbled(412))
        XCTAssertFalse(lossy.lines(limit: 5).contains { line in
            if case .lossless = line { return true }
            return false
        })
    }

    func testListeningHoursAreFloored() {
        XCTAssertEqual(proof(totalDurationSeconds: 0).listeningHours, 0)
        XCTAssertEqual(proof(totalDurationSeconds: 3_599).listeningHours, 0)
        XCTAssertEqual(proof(totalDurationSeconds: 3_600).listeningHours, 1)
        XCTAssertEqual(proof(totalDurationSeconds: 7_199.9).listeningHours, 1)
        XCTAssertEqual(proof(totalDurationSeconds: 7_200).listeningHours, 2)
        XCTAssertEqual(proof(totalDurationSeconds: 1_656_000).listeningHours, 460)
    }

    func testListeningHoursNeverTrapOnABadTotal() {
        XCTAssertEqual(proof(totalDurationSeconds: -50).listeningHours, 0)
        XCTAssertEqual(proof(totalDurationSeconds: .nan).listeningHours, 0)
        XCTAssertEqual(proof(totalDurationSeconds: .infinity).listeningHours, 0)
    }

    func testLosslessLineStillRendersWhenHoursRoundToZero() {
        XCTAssertEqual(
            proof(losslessTrackCount: 12, totalDurationSeconds: 2_400).lines(limit: 1),
            [.lossless(tracks: 12, hours: 0)]
        )
    }

    func testPlaysAreScrobbledWhenLastFMIsConnected() {
        XCTAssertEqual(proof(playsAreScrobbled: true).lines()[1], .scrobbled(412))
    }

    func testPlaysAreCountedWhenLastFMIsNotConnected() {
        XCTAssertEqual(proof(playsAreScrobbled: false).lines()[1], .playsCounted(412))
    }

    func testScrobbledAndCountedNeverBothAppear() {
        for scrobbled in [true, false] {
            let lines = proof(playsAreScrobbled: scrobbled).lines(limit: 5)
            let playLines = lines.filter { line in
                switch line {
                case .scrobbled, .playsCounted: return true
                default: return false
                }
            }
            XCTAssertEqual(playLines.count, 1, "scrobbled=\(scrobbled)")
        }
    }

    func testZeroPlaysSkipsBothPlayLines() {
        XCTAssertEqual(
            proof(plays: 0, playsAreScrobbled: true).lines(limit: 5),
            [.lossless(tracks: 2_619, hours: 460), .lyrics(903), .covers(191), .aiReviewed(1_402)]
        )
    }
}
