import XCTest
@testable import FlaccyCore

final class LibraryDebutTests: XCTestCase {

    private func job(
        _ activity: EnrichmentJobProgress.Activity,
        remaining: Int = 0
    ) -> EnrichmentJobProgress {
        EnrichmentJobProgress(
            activity: activity,
            scope: .album,
            remaining: remaining,
            completedThisRun: 0,
            exhausted: 0,
            currentTitle: nil,
            startedAt: nil
        )
    }

    private func directorInFinishing() -> LibraryDebutDirector {
        var director = LibraryDebutDirector()
        director.advance(load: .idle, job: job(.running, remaining: 200), albumCount: 214,
                         elapsedInFinishing: 0)
        XCTAssertEqual(director.act, .finishing)
        return director
    }

    func testDebutIsNotWrittenForAnEmptyLibrary() {
        var director = LibraryDebutDirector()
        XCTAssertTrue(
            director.advance(load: .idle, job: job(.idle), albumCount: 0, elapsedInFinishing: 0)
        )
        XCTAssertEqual(director.act, .done)
    }

    func testActsNeverMoveBackwards() {
        var director = directorInFinishing()
        XCTAssertFalse(
            director.advance(
                load: LibraryLoadProgress(phase: .readingTags, completed: 1, total: 500),
                job: job(.running, remaining: 200),
                albumCount: 214,
                elapsedInFinishing: 0
            )
        )
        XCTAssertEqual(director.act, .finishing)

        director.advance(load: .idle, job: job(.idle), albumCount: 214, elapsedInFinishing: 0)
        XCTAssertEqual(director.act, .summary)
        XCTAssertFalse(
            director.advance(load: .idle, job: job(.running, remaining: 5), albumCount: 214,
                             elapsedInFinishing: 0)
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testFinishingEndsWhenTheQueueDrains() {
        var director = directorInFinishing()
        XCTAssertFalse(
            director.advance(load: .idle, job: job(.running, remaining: 7), albumCount: 214,
                             elapsedInFinishing: 3)
        )
        XCTAssertEqual(director.act, .finishing)

        XCTAssertTrue(
            director.advance(load: .idle, job: job(.running, remaining: 0), albumCount: 214,
                             elapsedInFinishing: 4)
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testFinishingHoldsUntilTheJobHasReportedOnce() {
        var director = directorInFinishing()
        XCTAssertFalse(
            director.advance(load: .idle, job: job(.idle), albumCount: 214,
                             elapsedInFinishing: 1, jobHeardFrom: false)
        )
        XCTAssertEqual(director.act, .finishing)

        XCTAssertTrue(
            director.advance(load: .idle, job: job(.idle), albumCount: 214,
                             elapsedInFinishing: 1, jobHeardFrom: true)
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testTheCurtainStillEndsFinishingWhenTheJobNeverReports() {
        var director = directorInFinishing()
        XCTAssertTrue(
            director.advance(
                load: .idle, job: job(.idle), albumCount: 214,
                elapsedInFinishing: LibraryDebutDirector.curtainBudget, jobHeardFrom: false
            )
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testFinishingEndsAtTheCurtainBudget() {
        var director = directorInFinishing()
        XCTAssertFalse(
            director.advance(
                load: .idle, job: job(.running, remaining: 800), albumCount: 214,
                elapsedInFinishing: LibraryDebutDirector.curtainBudget - 0.01
            )
        )
        XCTAssertTrue(
            director.advance(
                load: .idle, job: job(.running, remaining: 800), albumCount: 214,
                elapsedInFinishing: LibraryDebutDirector.curtainBudget
            )
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testFinishingEndsImmediatelyWhenTheJobNeedsAnEntitlement() {
        var director = directorInFinishing()
        XCTAssertTrue(
            director.advance(load: .idle, job: job(.needsEntitlement, remaining: 128),
                             albumCount: 214, elapsedInFinishing: 0)
        )
        XCTAssertEqual(director.act, .summary)
    }

    func testSummaryRoundTripsThroughCodable() throws {
        let summary = LibraryDebutSummary(
            trackCount: 2_847,
            albumCount: 214,
            artistCount: 38,
            coversResolved: 191,
            albumsDated: 168,
            aiCleanedTracks: 1_402,
            losslessTrackCount: 2_619,
            averageBitrate: 1_984,
            totalDurationSeconds: 1_656_000,
            completedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(LibraryDebutSummary.self, from: data)

        XCTAssertEqual(decoded, summary)
    }
}
