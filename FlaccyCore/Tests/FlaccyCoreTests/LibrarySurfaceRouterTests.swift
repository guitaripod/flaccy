import XCTest
@testable import FlaccyCore

final class LibrarySurfaceRouterTests: XCTestCase {

    private func job(
        _ activity: EnrichmentJobProgress.Activity,
        remaining: Int = 0,
        completedThisRun: Int = 0
    ) -> EnrichmentJobProgress {
        EnrichmentJobProgress(
            activity: activity,
            scope: .album,
            remaining: remaining,
            completedThisRun: completedThisRun,
            exhausted: 0,
            currentTitle: nil,
            startedAt: nil
        )
    }

    func testRelaunchWithALibraryNeverPresentsTheDebut() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: LibraryLoadProgress(phase: .readingTags, completed: 1, total: 100),
            job: job(.idle),
            debutCompleted: false,
            hasLibrary: true,
            elapsed: 0
        )
        XCTAssertEqual(surface, .ambient)
    }

    func testFirstBuildPresentsTheDebutImmediately() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: LibraryLoadProgress(phase: .openingLibrary),
            job: job(.idle),
            debutCompleted: false,
            hasLibrary: false,
            elapsed: 0
        )
        XCTAssertEqual(surface, .debut)
    }

    func testDebutStaysPresentedUntilItIsReleased() {
        var router = LibrarySurfaceRouter()
        XCTAssertEqual(
            router.route(
                load: LibraryLoadProgress(phase: .findingFiles),
                job: job(.idle),
                debutCompleted: false,
                hasLibrary: false,
                elapsed: 0
            ),
            .debut
        )

        XCTAssertEqual(
            router.route(
                load: .idle,
                job: job(.idle),
                debutCompleted: false,
                hasLibrary: true,
                elapsed: 5
            ),
            .debut
        )

        router.releaseDebut()

        XCTAssertEqual(
            router.route(
                load: .idle,
                job: job(.idle),
                debutCompleted: true,
                hasLibrary: true,
                elapsed: 5
            ),
            .none
        )
    }

    func testCompletedDebutIsNeverPresentedAgain() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: LibraryLoadProgress(phase: .buildingAlbums, completed: 3, total: 9),
            job: job(.idle),
            debutCompleted: true,
            hasLibrary: false,
            elapsed: 0
        )
        XCTAssertEqual(surface, .none)
    }

    func testAmbientWaitsForTheGrace() {
        var router = LibrarySurfaceRouter()
        XCTAssertEqual(
            router.route(
                load: .idle,
                job: job(.running, remaining: 12, completedThisRun: 1),
                debutCompleted: true,
                hasLibrary: true,
                elapsed: LibrarySurfaceRouter.ambientGrace - 0.01
            ),
            .none
        )
        XCTAssertEqual(
            router.route(
                load: .idle,
                job: job(.running, remaining: 12, completedThisRun: 1),
                debutCompleted: true,
                hasLibrary: true,
                elapsed: LibrarySurfaceRouter.ambientGrace
            ),
            .ambient
        )
    }

    func testAmbientIsHiddenForAJobThatHasCompletedNothing() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: .idle,
            job: job(.running, remaining: 400, completedThisRun: 0),
            debutCompleted: true,
            hasLibrary: true,
            elapsed: 30
        )
        XCTAssertEqual(surface, .none)
    }

    func testAmbientAppearsAfterTheFirstCompletion() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: .idle,
            job: job(.running, remaining: 399, completedThisRun: 1),
            debutCompleted: true,
            hasLibrary: true,
            elapsed: 1
        )
        XCTAssertEqual(surface, .ambient)
    }

    func testWaitingForNetworkKeepsTheAmbientSurface() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: .idle,
            job: job(.waitingForNetwork, remaining: 300, completedThisRun: 4),
            debutCompleted: true,
            hasLibrary: true,
            elapsed: 12
        )
        XCTAssertEqual(surface, .ambient)
    }

    func testNeedsEntitlementNeverRaisesTheAmbientSurface() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: .idle,
            job: job(.needsEntitlement, remaining: 90, completedThisRun: 40),
            debutCompleted: true,
            hasLibrary: true,
            elapsed: 60
        )
        XCTAssertEqual(surface, .none)
    }

    func testSurfaceIsNoneWhenNothingIsHappening() {
        var router = LibrarySurfaceRouter()
        let surface = router.route(
            load: .idle,
            job: .idle,
            debutCompleted: true,
            hasLibrary: true,
            elapsed: 0
        )
        XCTAssertEqual(surface, .none)
    }
}
