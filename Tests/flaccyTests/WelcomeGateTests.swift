import XCTest
@testable import flaccy

nonisolated final class WelcomeGateTests: XCTestCase {

    func testANewInstallWithNothingInItSeesTheWelcome() {
        XCTAssertTrue(WelcomeGate.shouldPresent(seen: false, hadIndexedLibrary: false, serverCount: 0, isAutomated: false, forced: false))
    }

    func testItIsShownOnlyOnce() {
        XCTAssertFalse(WelcomeGate.shouldPresent(seen: true, hadIndexedLibrary: false, serverCount: 0, isAutomated: false, forced: false))
    }

    func testAPersonWithMusicOrAServerNeverSeesIt() {
        XCTAssertFalse(WelcomeGate.shouldPresent(seen: false, hadIndexedLibrary: true, serverCount: 0, isAutomated: false, forced: false))
        XCTAssertFalse(WelcomeGate.shouldPresent(seen: false, hadIndexedLibrary: false, serverCount: 1, isAutomated: false, forced: false))
    }

    func testAnAutomatedRunOpensWhereItAskedUnlessItForcesTheWelcome() {
        XCTAssertFalse(WelcomeGate.shouldPresent(seen: false, hadIndexedLibrary: false, serverCount: 0, isAutomated: true, forced: false))
        XCTAssertTrue(WelcomeGate.shouldPresent(seen: true, hadIndexedLibrary: true, serverCount: 2, isAutomated: true, forced: true))
    }

    func testTestsRoutesAndLaunchArgumentsCountAsAutomated() {
        XCTAssertFalse(WelcomeGate.isAutomatedRun(arguments: ["/app"], environment: [:]))
        XCTAssertTrue(WelcomeGate.isAutomatedRun(arguments: ["/app", "--seed-screenshots"], environment: [:]))
        XCTAssertTrue(WelcomeGate.isAutomatedRun(arguments: ["/app"], environment: ["FLACCY_ROUTE": "home"]))
        XCTAssertTrue(WelcomeGate.isAutomatedRun(arguments: ["/app"], environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    func testTheForcedWelcomeCanOpenOnTheServerStep() {
        XCTAssertTrue(WelcomeGate.isForced(arguments: ["/app", "--show-welcome"]))
        XCTAssertFalse(WelcomeGate.opensOnServerStep(arguments: ["/app", "--show-welcome"]))
        XCTAssertTrue(WelcomeGate.opensOnServerStep(arguments: ["/app", "--show-welcome", "server"]))
        XCTAssertFalse(WelcomeGate.isForced(arguments: ["/app"]))
    }

    func testTheSetupGuideLinkIsTheSitePage() {
        XCTAssertEqual(WelcomeCopy.setupGuideURL.absoluteString, "https://midgarcorp.cc/flaccy/server")
    }
}
