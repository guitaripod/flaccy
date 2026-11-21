import UIKit
import XCTest
@testable import flaccy

nonisolated final class ShowcaseTests: XCTestCase {

    func testADeviceThatHasSeenNoEditionOrAnOlderOneIsShownIt() {
        XCTAssertTrue(ShowcaseGate.shouldPresent(seenEdition: 0, isAutomated: false, forced: false))
        XCTAssertTrue(ShowcaseGate.shouldPresent(seenEdition: ShowcaseGate.edition - 1, isAutomated: false, forced: false))
    }

    func testItIsShownOnlyOncePerEdition() {
        XCTAssertFalse(ShowcaseGate.shouldPresent(seenEdition: ShowcaseGate.edition, isAutomated: false, forced: false))
        XCTAssertFalse(ShowcaseGate.shouldPresent(seenEdition: ShowcaseGate.edition + 1, isAutomated: false, forced: false))
    }

    func testAnAutomatedRunOpensWhereItAskedUnlessItForcesTheShowcase() {
        XCTAssertFalse(ShowcaseGate.shouldPresent(seenEdition: 0, isAutomated: true, forced: false))
        XCTAssertTrue(ShowcaseGate.shouldPresent(seenEdition: ShowcaseGate.edition, isAutomated: true, forced: true))
    }

    func testTestsRoutesAndOtherLaunchArgumentsCountAsAutomated() {
        XCTAssertFalse(ShowcaseGate.isAutomatedRun(arguments: ["/app"], environment: [:]))
        XCTAssertFalse(ShowcaseGate.isAutomatedRun(arguments: ["/app", ShowcaseGate.forceArgument], environment: [:]))
        XCTAssertTrue(ShowcaseGate.isAutomatedRun(arguments: ["/app", "--seed-screenshots"], environment: [:]))
        XCTAssertTrue(ShowcaseGate.isAutomatedRun(arguments: ["/app", "--show-welcome"], environment: [:]))
        XCTAssertTrue(ShowcaseGate.isAutomatedRun(arguments: ["/app"], environment: ["FLACCY_ROUTE": "home"]))
        XCTAssertTrue(ShowcaseGate.isAutomatedRun(arguments: ["/app"], environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    func testTheForcedShowcaseCanOpenOnItsSecondPage() {
        XCTAssertTrue(ShowcaseGate.isForced(arguments: ["/app", "--show-showcase"]))
        XCTAssertFalse(ShowcaseGate.opensOnEverything(arguments: ["/app", "--show-showcase"]))
        XCTAssertTrue(ShowcaseGate.opensOnEverything(arguments: ["/app", "--show-showcase", "everything"]))
        XCTAssertFalse(ShowcaseGate.isForced(arguments: ["/app"]))
    }

    func testTheFirstPageStaysCompact() {
        XCTAssertEqual(ShowcaseCopy.highlights.count, 4)
        XCTAssertEqual(Set(ShowcaseCopy.highlights.map(\.id)).count, 4)
        for feature in ShowcaseCopy.highlights {
            XCTAssertLessThanOrEqual(feature.detail.count, 90, feature.id)
        }
    }

    func testEveryFeatureHasItsOwnNameAndASymbolTheSystemHas() {
        let features = ShowcaseCopy.sections(bringsMusicOverWiFi: true).flatMap(\.features) + ShowcaseCopy.highlights
        XCTAssertEqual(Set(features.map(\.title)).count, features.count)
        for feature in features {
            XCTAssertFalse(feature.detail.isEmpty, feature.id)
            XCTAssertNotNil(UIImage(systemName: feature.symbol), feature.symbol)
        }
    }

    func testThemesAreListedOnEveryDevicesShowcase() {
        for bringsMusicOverWiFi in [true, false] {
            let library = ShowcaseCopy.sections(bringsMusicOverWiFi: bringsMusicOverWiFi).first { $0.id == "library" }
            XCTAssertTrue(library?.features.contains { $0.id == "themes" } ?? false)
        }
    }

    func testWiFiTransferIsOnlyOfferedWhereItExists() {
        let withTransfer = ShowcaseCopy.sections(bringsMusicOverWiFi: true).flatMap(\.features).map(\.id)
        let without = ShowcaseCopy.sections(bringsMusicOverWiFi: false).flatMap(\.features).map(\.id)
        XCTAssertTrue(withTransfer.contains("bringIn"))
        XCTAssertFalse(without.contains("bringIn"))
        XCTAssertEqual(withTransfer.count, without.count + 1)
    }

    @MainActor
    func testAnEndedTrialIsLedToThePlansAndCanStillSayNotNow() {
        let footer = ShowcaseFooter.make(for: .expired)
        XCTAssertEqual(footer.primary, .plans)
        XCTAssertEqual(footer.primaryTitle, ShowcaseCopy.seePlans)
        XCTAssertEqual(footer.secondary, .listen)
        XCTAssertEqual(footer.secondaryTitle, ShowcaseCopy.notNow)
        XCTAssertEqual(footer.status, PaywallCopy.statusLine(for: .expired))
        XCTAssertTrue(footer.statusLeads)
    }

    @MainActor
    func testARunningTrialAndASecondLookListenFirstWithThePlansOneTapAway() {
        for state in [EntitlementState.trial(daysRemaining: 5), .secondLookReady] {
            let footer = ShowcaseFooter.make(for: state)
            XCTAssertEqual(footer.primary, .listen)
            XCTAssertEqual(footer.primaryTitle, ShowcaseCopy.proceed)
            XCTAssertEqual(footer.secondary, .plans)
            XCTAssertEqual(footer.status, PaywallCopy.statusLine(for: state))
        }
    }

    @MainActor
    func testFreeDaysThatWaitAreSaidAsPlainlyAsAnEndedTrial() {
        XCTAssertTrue(ShowcaseFooter.make(for: .secondLookReady).statusLeads)
        for state in [EntitlementState.trial(daysRemaining: 5), .trialNotStarted, .purchased(.lifetime), .purchased(.yearly)] {
            XCTAssertFalse(ShowcaseFooter.make(for: state).statusLeads, "\(state)")
        }
        XCTAssertFalse(ShowcaseFooter.make(for: nil).statusLeads)
    }

    @MainActor
    func testAnOwnerANewPersonAndAStoreThatHasNotAnsweredAreNeverSoldTo() {
        for state in [EntitlementState.purchased(.lifetime), .purchased(.yearly), .trialNotStarted] {
            let footer = ShowcaseFooter.make(for: state)
            XCTAssertEqual(footer.primary, .listen)
            XCTAssertNil(footer.secondary)
            XCTAssertNil(footer.secondaryTitle)
            XCTAssertNotNil(footer.status)
        }
        let unknown = ShowcaseFooter.make(for: nil)
        XCTAssertEqual(unknown.primary, .listen)
        XCTAssertNil(unknown.status)
        XCTAssertNil(unknown.secondary)
    }

    func testTheEntranceIsOverInAboutASecond() {
        let buttons = ShowcaseTiming.buttons(rowCount: ShowcaseCopy.highlights.count)
        XCTAssertLessThan(buttons + ShowcaseTiming.settle, 1.4)
        XCTAssertGreaterThan(ShowcaseTiming.row(1), ShowcaseTiming.row(0))
        XCTAssertGreaterThan(ShowcaseTiming.versionLands, ShowcaseTiming.version)
    }
}
