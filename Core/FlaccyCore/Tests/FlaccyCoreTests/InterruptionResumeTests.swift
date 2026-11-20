import XCTest
@testable import FlaccyCore

final class InterruptionResumeTests: XCTestCase {

    func testTheStandardChoiceResumesWhenTheOtherAppGoesQuiet() {
        XCTAssertEqual(InterruptionResume.standard, .whenQuiet)
        XCTAssertEqual(InterruptionResume(storedName: nil), .whenQuiet)
        XCTAssertEqual(InterruptionResume(storedName: "sometimes"), .whenQuiet)
        XCTAssertEqual(InterruptionResume(storedName: "whenHandedBack"), .whenHandedBack)
        XCTAssertEqual(InterruptionResume(storedName: "never"), .never)
    }

    func testAHandBackIsHonouredUnlessTheChoiceIsNever() {
        XCTAssertTrue(InterruptionResume.whenQuiet.resumes(onHandBack: true))
        XCTAssertTrue(InterruptionResume.whenHandedBack.resumes(onHandBack: true))
        XCTAssertFalse(InterruptionResume.never.resumes(onHandBack: true))
        for choice in InterruptionResume.allCases {
            XCTAssertFalse(choice.resumes(onHandBack: false))
        }
    }

    func testOnlyTheQuietChoiceKeepsListening() {
        XCTAssertTrue(InterruptionResume.whenQuiet.watchesForQuiet)
        XCTAssertFalse(InterruptionResume.whenHandedBack.watchesForQuiet)
        XCTAssertFalse(InterruptionResume.never.watchesForQuiet)
    }

    func testQuietAloneNeverResumes() {
        var watch = InterruptionQuietWatch()
        for _ in 0..<30 {
            XCTAssertFalse(watch.observe(otherAudioPlaying: false))
        }
    }

    func testQuietAloneIsEnoughWithThePlayerOnScreen() {
        var watch = InterruptionQuietWatch()
        XCTAssertFalse(watch.observe(otherAudioPlaying: false, playerIsOnScreen: true))
        XCTAssertTrue(watch.observe(otherAudioPlaying: false, playerIsOnScreen: true))
    }

    func testResumesAfterTheOtherAppWasHeardAndStayedQuiet() {
        var watch = InterruptionQuietWatch()
        XCTAssertFalse(watch.observe(otherAudioPlaying: true))
        XCTAssertFalse(watch.observe(otherAudioPlaying: false))
        XCTAssertTrue(watch.observe(otherAudioPlaying: false))
    }

    func testAPauseShorterThanTheQuietCountStartsItAgain() {
        var watch = InterruptionQuietWatch()
        XCTAssertFalse(watch.observe(otherAudioPlaying: true))
        XCTAssertFalse(watch.observe(otherAudioPlaying: false))
        XCTAssertFalse(watch.observe(otherAudioPlaying: true))
        XCTAssertFalse(watch.observe(otherAudioPlaying: false))
        XCTAssertTrue(watch.observe(otherAudioPlaying: false))
    }

    func testARefusedAttemptWaitsForTheQuietCountAgain() {
        var watch = InterruptionQuietWatch()
        _ = watch.observe(otherAudioPlaying: true)
        _ = watch.observe(otherAudioPlaying: false)
        XCTAssertTrue(watch.observe(otherAudioPlaying: false))
        watch.attemptWasRefused()
        XCTAssertFalse(watch.observe(otherAudioPlaying: false))
        XCTAssertTrue(watch.observe(otherAudioPlaying: false))
    }
}
