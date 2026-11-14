import XCTest
@testable import FlaccyCore

final class EqualizerDescriptionTests: XCTestCase {

    private func band(_ type: String, _ frequency: Double, _ gain: Double, _ q: Double, _ reason: String = "Why.") -> DescribedCurve.Band {
        DescribedCurve.Band(type: type, frequency: frequency, gain: gain, q: q, reason: reason)
    }

    func testRequestSendsTheSentenceOnOneLineAndNoBandsForAFlatProfile() {
        let flat = EqualizerProfile.graphic(name: "Flat", targets: Array(repeating: 0, count: GraphicSolver.centres.count))
        let request = EqualizerDescription.request("  warmer,\n less harsh  ", language: "Finnish", output: "headphones", device: "phone", inForce: flat)
        XCTAssertEqual(request.request, "warmer, less harsh")
        XCTAssertEqual(request.language, "Finnish")
        XCTAssertEqual(request.output, "headphones")
        XCTAssertEqual(request.device, "phone")
        XCTAssertTrue(request.bands.isEmpty)
    }

    func testRequestCutsALongSentenceAndSendsTheBandsInForceRounded() {
        let profile = EqualizerProfile.parametric(name: "Mine", bands: [
            EqualizerBand(type: .lowShelf, frequency: 80.04, gain: 5.96, q: 0.7071),
            EqualizerBand(type: .bell, frequency: 3000, gain: 0.1, q: 1),
            EqualizerBand(type: .bell, frequency: 5000, gain: -4, q: 2, isEnabled: false),
            EqualizerBand(type: .highPass, frequency: 30, gain: 0, q: 0.71),
        ])
        let request = EqualizerDescription.request(String(repeating: "x", count: 400), language: "English", output: "car", device: "phone", inForce: profile)
        XCTAssertEqual(request.request.count, EqualizerDescription.longestRequest)
        XCTAssertEqual(request.bands, [
            EqualizerDescriptionRequest.Band(type: "lowShelf", frequency: 80, gain: 6, q: 0.71),
            EqualizerDescriptionRequest.Band(type: "highPass", frequency: 30, gain: 0, q: 0.71),
        ])
    }

    func testRequestSendsTheTenBandsAGraphicProfileResolvesTo() {
        var targets = Array(repeating: 0.0, count: GraphicSolver.centres.count)
        targets[0] = 4
        targets[9] = -3
        let request = EqualizerDescription.request("more of this", language: "English", output: "other", device: "computer", inForce: .graphic(name: "Curve", targets: targets))
        XCTAssertFalse(request.bands.isEmpty)
        XCTAssertLessThanOrEqual(request.bands.count, EqualizerBand.maximumPerProfile)
        XCTAssertTrue(request.bands.allSatisfy { $0.type == "bell" })
    }

    func testSettleKeepsASaneCurveAsItIsWithItsReasons() throws {
        let curve = DescribedCurve(
            name: "Warm Evening",
            bands: [band("lowShelf", 90, 3, 0.71, "More weight."), band("bell", 3200, -2.5, 1.2, "Softer cymbals.")],
            note: "")
        let settled = try XCTUnwrap(EqualizerDescription.settle(curve, fallbackName: "Described"))
        XCTAssertEqual(settled.profile.name, "Warm Evening")
        XCTAssertEqual(settled.profile.kind, .parametric)
        XCTAssertTrue(settled.profile.isAutoPreamp)
        XCTAssertEqual(settled.profile.bands, [
            EqualizerBand(type: .lowShelf, frequency: 90, gain: 3, q: 0.71),
            EqualizerBand(type: .bell, frequency: 3200, gain: -2.5, q: 1.2),
        ])
        XCTAssertEqual(settled.reasons, ["More weight.", "Softer cymbals."])
        XCTAssertEqual(settled.note, "")
        XCTAssertFalse(settled.profile.isBuiltIn)
    }

    func testSettleForcesEveryValueIntoRangeAndDropsWhatIsNoBand() throws {
        let curve = DescribedCurve(
            name: "  ",
            bands: [
                band("lowShelf", 5, 40, 0.01, " Deep\nbass. "),
                band("notch", 1000, -6, 4),
                band("highPass", 90_000, 9, 99),
                band("bell", 1000, 0.1, 1),
                band("bell", .nan, 3, 1),
                band("bell", 2000, .infinity, 1),
            ],
            note: " An equalizer\ncannot make it louder. ")
        let settled = try XCTUnwrap(EqualizerDescription.settle(curve, fallbackName: "Described"))
        XCTAssertEqual(settled.profile.name, "Described")
        XCTAssertEqual(settled.profile.bands, [
            EqualizerBand(type: .lowShelf, frequency: 20, gain: 12, q: 0.3),
            EqualizerBand(type: .highPass, frequency: 20_000, gain: 0, q: 1),
        ])
        XCTAssertEqual(settled.reasons, ["Deep bass.", "Why."])
        XCTAssertEqual(settled.note, "An equalizer cannot make it louder.")
    }

    func testSettleKeepsTenBandsAtMostAndAReasonForEach() throws {
        let many = (1...14).map { band("bell", Double($0) * 400, -2, 4, "Band \($0).") }
        let settled = try XCTUnwrap(EqualizerDescription.settle(DescribedCurve(name: "Many", bands: many, note: ""), fallbackName: "Described"))
        XCTAssertEqual(settled.profile.bands.count, EqualizerBand.maximumPerProfile)
        XCTAssertEqual(settled.reasons.count, EqualizerBand.maximumPerProfile)
        XCTAssertEqual(settled.reasons.last, "Band 10.")
    }

    func testSettleScalesStackedBoostsDownToTheTopOfThePlot() throws {
        let stacked = DescribedCurve(
            name: "Wall Shaker",
            bands: [band("lowShelf", 100, 12, 0.71), band("bell", 60, 12, 0.8), band("bell", 80, 10, 1), band("bell", 4000, -4, 1)],
            note: "")
        XCTAssertGreaterThan(Headroom.peakBoost(of: stacked.bands.map { EqualizerBand(type: EqualizerFilterType(rawValue: $0.type)!, frequency: $0.frequency, gain: $0.gain, q: $0.q) }), 24)
        let settled = try XCTUnwrap(EqualizerDescription.settle(stacked, fallbackName: "Described"))
        let peak = Headroom.peakBoost(of: settled.profile.resolvedBands())
        XCTAssertLessThanOrEqual(peak, EqualizerDescription.highestBoost + 0.1)
        XCTAssertGreaterThan(peak, EqualizerDescription.highestBoost - 1.5)
        XCTAssertEqual(settled.profile.bands.count, 4)
        XCTAssertLessThan(settled.profile.bands[3].gain, 0)
        XCTAssertGreaterThanOrEqual(settled.profile.preamp(), -EqualizerDescription.highestBoost - 0.2)
    }

    func testSettleKeepsAPassFilterFromRingingAboveThePlot() throws {
        let ringing = DescribedCurve(name: "Radio", bands: [band("highPass", 300, 0, 10), band("lowPass", 3000, 0, 8), band("bell", 1200, 3, 1)], note: "")
        let settled = try XCTUnwrap(EqualizerDescription.settle(ringing, fallbackName: "Described"))
        XCTAssertEqual(settled.profile.bands.map(\.q), [1, 1, 1])
        XCTAssertEqual(settled.profile.bands[2].gain, 3)
        XCTAssertLessThan(Headroom.peakBoost(of: settled.profile.resolvedBands()), 5)
    }

    func testSettleLeavesACurveInsideThePlotUntouched() throws {
        let bands = [band("lowShelf", 80, 6, 0.71), band("highShelf", 9000, 5, 0.71), band("bell", 2500, -3, 1.4)]
        let settled = try XCTUnwrap(EqualizerDescription.settle(DescribedCurve(name: "V", bands: bands, note: ""), fallbackName: "Described"))
        XCTAssertEqual(settled.profile.bands.map(\.gain), [6, 5, -3])
    }

    func testSettleAnswersNothingForACurveWithNoUsableBand() {
        XCTAssertNil(EqualizerDescription.settle(DescribedCurve(name: "Flat", bands: [], note: "Describe a sound."), fallbackName: "Described"))
        XCTAssertNil(EqualizerDescription.settle(DescribedCurve(name: "Flat", bands: [band("bell", 1000, 0, 1), band("comb", 500, 3, 1)], note: ""), fallbackName: "Described"))
    }

    func testReplyDecodesFromTheServicesJSON() throws {
        let json = #"{"name":"Clearer vocals","bands":[{"type":"bell","frequency":2500,"gain":3,"q":1,"reason":"Brings the singer forward."}],"note":""}"#
        let curve = try JSONDecoder().decode(DescribedCurve.self, from: Data(json.utf8))
        XCTAssertEqual(curve, DescribedCurve(name: "Clearer vocals", bands: [band("bell", 2500, 3, 1, "Brings the singer forward.")], note: ""))
    }
}
