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
        XCTAssertEqual(LibraryLoadPhase.findingFiles.start, 0.02, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.readingTags.start, 0.15, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.identifyingMusic.start, 0.60, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.buildingAlbums.start, 0.75, accuracy: 0.0001)
        XCTAssertEqual(LibraryLoadPhase.enrichingArtwork.start, 0.80, accuracy: 0.0001)
    }

    func testIdleProgressIsZeroAndInactive() {
        let progress = LibraryLoadProgress.idle
        XCTAssertFalse(progress.isActive)
        XCTAssertEqual(progress.fractionCompleted, 0, accuracy: 0.0001)
    }

    func testFractionCombinesPhaseStartAndPhaseProgress() {
        let progress = LibraryLoadProgress(phase: .readingTags, completed: 50, total: 100)
        XCTAssertEqual(progress.phaseFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress.fractionCompleted, 0.15 + 0.45 * 0.5, accuracy: 0.0001)
    }

    func testIndeterminatePhaseCountsAsHalfDone() {
        let progress = LibraryLoadProgress(phase: .findingFiles)
        XCTAssertFalse(progress.isDeterminate)
        XCTAssertEqual(progress.fractionCompleted, 0.02 + 0.13 * 0.5, accuracy: 0.0001)
    }

    func testFractionNeverExceedsOne() {
        let progress = LibraryLoadProgress(phase: .enrichingArtwork, completed: 999, total: 10)
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

    func testOnlyPreLibraryPhasesBlockTheLibrary() {
        XCTAssertFalse(LibraryLoadPhase.idle.blocksLibrary)
        XCTAssertTrue(LibraryLoadPhase.findingFiles.blocksLibrary)
        XCTAssertTrue(LibraryLoadPhase.buildingAlbums.blocksLibrary)
        XCTAssertFalse(LibraryLoadPhase.enrichingArtwork.blocksLibrary)
    }
}
