import XCTest
@testable import FlaccyCore

final class LibraryLoadProgressTests: XCTestCase {

    func testPhaseWeightsCoverTheWholeLoad() {
        let total = LibraryLoadPhase.allCases.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
    }

    func testPhaseStartsAreCumulative() {
        XCTAssertEqual(LibraryLoadPhase.idle.start, 0, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.openingLibrary.start, 0, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.findingFiles.start, 0.05, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.readingTags.start, 0.18, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.buildingAlbums.start, 0.85, accuracy: 0.0001)
    }

    func testStartsTableMatchesAccumulatedWeights() {
        var accumulated = 0.0
        for phase in LibraryLoadPhase.allCases {
            XCTAssertEqual(phase.start, accumulated, accuracy: 0.0001, "\(phase)")
            accumulated += phase.weight
        }
        XCTAssertEqual(accumulated, 1.0, accuracy: 0.0001)
    }

    func testEveryActivePhaseBlocksTheLibrary() {
        XCTAssertFalse(LibraryLoadPhase.idle.blocksLibrary)
        for phase in LibraryLoadPhase.allCases where phase != .idle {
            XCTAssertTrue(phase.blocksLibrary, "\(phase)")
        }
    }

    func testIdleProgressIsZeroAndInactive() {
        let progress = LibraryLoadProgress.idle
        XCTAssertFalse(progress.isActive)
        XCTAssertEqual(progress.fractionCompleted, 0, accuracy: 0.0001)
    }

    func testFractionCombinesPhaseStartAndPhaseProgress() {
        let progress = LibraryLoadProgress(phase: .readingTags, completed: 50, total: 100)
        XCTAssertEqual(progress.phaseFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress.fractionCompleted, 0.18 + 0.67 * 0.5, accuracy: 0.0001)
    }

    func testIndeterminatePhaseCountsAsHalfDone() {
        let progress = LibraryLoadProgress(phase: .findingFiles)
        XCTAssertFalse(progress.isDeterminate)
        XCTAssertEqual(progress.fractionCompleted, 0.05 + 0.13 * 0.5, accuracy: 0.0001)
    }

    func testFractionNeverExceedsOne() {
        let progress = LibraryLoadProgress(phase: .buildingAlbums, completed: 999, total: 10)
        XCTAssertEqual(progress.fractionCompleted, 1.0, accuracy: 0.0001)
    }

    func testAFinishedLoadReachesAnHonestHundredPercent() {
        let progress = LibraryLoadProgress(phase: .buildingAlbums, completed: 214, total: 214)
        XCTAssertEqual(progress.fractionCompleted, 1.0, accuracy: 0.0001)
    }

    func testFractionIsMonotonicAcrossPhases() {
        var last = 0.0
        for phase in LibraryLoadPhase.allCases where phase != .idle {
            for completed in stride(from: 0, through: 10, by: 1) {
                let fraction = LibraryLoadProgress(phase: phase, completed: completed, total: 10)
                    .fractionCompleted
                XCTAssertGreaterThanOrEqual(fraction, last - 0.0001, "\(phase) \(completed)")
                last = fraction
            }
        }
    }

    func testTrackerHoldsFractionAtHighWaterMarkWhenWorkGrows() {
        let tracker = LibraryLoadProgressTracker()
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .readingTags, completed: 90, total: 100) }
        let peak = tracker.displayFraction
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .readingTags, completed: 90, total: 1000) }
        XCTAssertEqual(tracker.displayFraction, peak, accuracy: 0.0001)
    }

    func testTrackerResetsHighWaterWhenPhaseMovesBackwards() {
        let tracker = LibraryLoadProgressTracker()
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .buildingAlbums, completed: 9, total: 10) }
        XCTAssertGreaterThan(tracker.displayFraction, 0.9)

        let restarted = tracker.update { $0 = LibraryLoadProgress(phase: .openingLibrary) }

        XCTAssertNotNil(restarted)
        XCTAssertEqual(tracker.displayFraction, LibraryLoadPhase.openingLibrary.weight * 0.5, accuracy: 0.0001)
    }

    func testTrackerDropsImperceptibleUpdates() {
        let tracker = LibraryLoadProgressTracker(minimumInterval: 60)
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .readingTags, completed: 0, total: 10_000) }
        XCTAssertNil(tracker.update { $0.completed = 1 })
        XCTAssertNil(tracker.update { $0.completed = 2 })
    }

    func testTrackerPublishesCounterTicksDuringIndeterminatePhases() {
        let tracker = LibraryLoadProgressTracker(minimumInterval: 0)
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .findingFiles) }
        XCTAssertNotNil(tracker.update { $0.filesFound = 12 })
    }

    func testTrackerDropsUpdatesThatChangeNothing() {
        let tracker = LibraryLoadProgressTracker(minimumInterval: 0)
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .findingFiles, filesFound: 3) }
        XCTAssertNil(tracker.update { $0.filesFound = 3 })
    }

    func testTrackerPublishesPhaseChanges() {
        let tracker = LibraryLoadProgressTracker()
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .findingFiles) }
        XCTAssertNotNil(tracker.update { $0.phase = .readingTags })
    }

    func testTrackerPublishesMeaningfulMovement() {
        let tracker = LibraryLoadProgressTracker()
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .readingTags, completed: 0, total: 100) }
        XCTAssertNotNil(tracker.update { $0.completed = 20 })
    }

    func testFinishResetsTheTracker() {
        let tracker = LibraryLoadProgressTracker()
        tracker.update(force: true) { $0 = LibraryLoadProgress(phase: .readingTags, completed: 5, total: 10) }
        XCTAssertEqual(tracker.finish(), .idle)
        XCTAssertEqual(tracker.displayFraction, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.progress.isActive)
    }
}
