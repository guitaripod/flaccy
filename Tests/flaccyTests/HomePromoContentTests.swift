import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class HomePromoContentTests: XCTestCase {

    private let lines: [PaywallProof.Line] = [.lossless(tracks: 120, hours: 9), .playsCounted(40), .lyrics(12), .covers(30)]

    @MainActor func testGetStartedCarriesTheTrialFootnoteOnlyBeforeTheTrialStarts() {
        let manager = PurchaseManager(store: nil)
        guard case .getStarted(let content) = HomePromoContent.make(for: .getStarted, proof: [], manager: manager) else {
            return XCTFail("expected the get-started card")
        }
        XCTAssertEqual(content.title, HomeCopy.getStartedTitle)
        XCTAssertEqual(content.footnote, PaywallCopy.trialStartsLine)
    }

    @MainActor func testTheTrialNoteIsThePaywallsOwnSentence() {
        let manager = PurchaseManager(store: nil)
        XCTAssertEqual(
            HomePromoContent.make(for: .trialStartsOnFirstPlay, proof: [], manager: manager),
            .note(PaywallCopy.trialStartsLine)
        )
    }

    @MainActor func testKeepListeningQuotesAtMostThreeLinesAndOffersRestore() {
        let manager = PurchaseManager(store: nil)
        guard case .plan(let plan) = HomePromoContent.make(for: .keepListening(welcomeBack: false), proof: lines, manager: manager) else {
            return XCTFail("expected a plan card")
        }
        XCTAssertEqual(plan.kicker, PaywallCopy.statusLine(for: .expired))
        XCTAssertEqual(plan.title, HomeCopy.keepListeningTitle)
        XCTAssertEqual(plan.proofLines, lines.prefix(3).map(PaywallCopy.proofLine))
        XCTAssertEqual(plan.primaryTitle, PaywallCopy.purchaseTitle(plan: .lifetime, offer: nil))
        XCTAssertEqual(plan.caption, PaywallCopy.lifetimeCaption(lifetime: nil, yearly: nil, welcomeBackEnds: nil))
        XCTAssertTrue(plan.offersRestore)
    }

    @MainActor func testTheLastDayCardWithNothingToQuoteDoesNotTitleItselfAfterTheProof() {
        let manager = PurchaseManager(store: nil)
        guard case .plan(let plan) = HomePromoContent.make(for: .lastDay, proof: [], manager: manager) else {
            return XCTFail("expected a plan card")
        }
        XCTAssertEqual(plan.title, HomeCopy.keepListeningTitle)
        XCTAssertTrue(plan.proofLines.isEmpty)
        XCTAssertNil(plan.caption)
        XCTAssertFalse(plan.offersRestore)
    }

    @MainActor func testEveryEntitlementStateMapsToItsPhase() {
        XCTAssertEqual(HomePromo.Phase(.trialNotStarted), .notStarted)
        XCTAssertEqual(HomePromo.Phase(.trial(daysRemaining: 3)), .trial(daysRemaining: 3))
        XCTAssertEqual(HomePromo.Phase(.expired), .expired)
        XCTAssertEqual(HomePromo.Phase(.purchased(.lifetime)), .purchased)
        XCTAssertEqual(HomePromo.Phase(.purchased(.yearly)), .purchased)
    }
}
