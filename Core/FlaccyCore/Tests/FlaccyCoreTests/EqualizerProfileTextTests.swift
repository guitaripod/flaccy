import XCTest
@testable import FlaccyCore

/// Mirrored by `linux/shared/src/equalizer/profile_text.rs`.
final class EqualizerProfileTextTests: XCTestCase {

    private let autoEqSample = """
    Preamp: -6.2 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON PK Fc 210 Hz Gain -2.4 dB Q 0.80
    Filter 3: ON PK Fc 3100 Hz Gain 4.1 dB Q 2.10
    Filter 4: ON HSC Fc 12000 Hz Gain -1.5 dB Q 0.70
    """

    func testReadsAnAutoEqProfile() throws {
        let parsed = try XCTUnwrap(EqualizerProfileText.parse(autoEqSample, fallbackName: "Imported"))

        XCTAssertEqual(parsed.droppedFilters, 0)
        XCTAssertEqual(parsed.profile.kind, .parametric)
        XCTAssertEqual(parsed.profile.name, "Imported")
        XCTAssertEqual(parsed.profile.bands.map(\.type), [.lowShelf, .bell, .bell, .highShelf])
        XCTAssertEqual(parsed.profile.bands[2].frequency, 3_100)
        XCTAssertEqual(parsed.profile.bands[2].gain, 4.1)
        XCTAssertEqual(parsed.profile.bands[2].q, 2.1)
        XCTAssertFalse(parsed.profile.isAutoPreamp)
        XCTAssertEqual(parsed.profile.manualPreamp, -6.2)
    }

    func testAPreampThatMatchesTheAutomaticOneStaysAutomatic() throws {
        let bands = [EqualizerBand(type: .bell, frequency: 1_000, gain: 6, q: 1)]
        let auto = Headroom.autoPreamp(for: bands)
        let text = "Preamp: \(auto) dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1"

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "x"))

        XCTAssertTrue(parsed.profile.isAutoPreamp)
    }

    func testAFilterThatIsOffIsKeptButDisabled() throws {
        let text = "Filter 1: OFF PK Fc 500 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 2000 Hz Gain -3 dB Q 1"

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "x"))

        XCTAssertEqual(parsed.profile.bands.map(\.isEnabled), [false, true])
    }

    func testPassFiltersCarryNoGain() throws {
        let text = "Filter 1: ON HPQ Fc 30 Hz Q 0.71\nFilter 2: ON LP Fc 18000 Hz Gain 4 dB Q 0.71"

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "x"))

        XCTAssertEqual(parsed.profile.bands.map(\.type), [.highPass, .lowPass])
        XCTAssertEqual(parsed.profile.bands.map(\.gain), [0, 0])
    }

    func testMoreThanTenFiltersKeepsTheStrongestAndSaysWhatItDropped() throws {
        let lines = (1...12).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain \($0 == 3 ? 0.1 : 4) dB Q 1" }

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(lines.joined(separator: "\n"), fallbackName: "x"))

        XCTAssertEqual(parsed.profile.bands.count, 10)
        XCTAssertEqual(parsed.droppedFilters, 2)
        XCTAssertFalse(parsed.profile.bands.contains { $0.frequency == 300 })
    }

    func testAFilterOfAnUnknownKindIsCountedNotImported() throws {
        let text = "Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1\nFilter 2: ON NO Fc 50 Hz Q 30"

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "x"))

        XCTAssertEqual(parsed.profile.bands.count, 1)
        XCTAssertEqual(parsed.droppedFilters, 1)
    }

    func testAGraphicEQLineBecomesATenBandProfile() throws {
        let text = "GraphicEQ: 20 0; 100 2; 1000 4; 10000 -2; 20000 -2"

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "x"))

        XCTAssertEqual(parsed.profile.kind, .graphic)
        XCTAssertEqual(parsed.profile.targets.count, 10)
        XCTAssertEqual(parsed.profile.targets[5], 4, accuracy: 1e-9)
        XCTAssertEqual(parsed.profile.targets[9], -2 + (0.0), accuracy: 1.5)
    }

    func testTextWithNothingToReadIsRefused() {
        XCTAssertNil(EqualizerProfileText.parse("hello\nworld", fallbackName: "x"))
        XCTAssertNil(EqualizerProfileText.parse("", fallbackName: "x"))
        XCTAssertNil(EqualizerProfileText.parse("Preamp: -3 dB", fallbackName: "x"))
    }

    func testNumbersThatAreNotNumbersAreNotRead() {
        XCTAssertNil(EqualizerProfileText.parse("Filter 1: ON PK Fc nan Hz Gain 3 dB Q 1", fallbackName: "x"))
        let parsed = EqualizerProfileText.parse("Filter 1: ON PK Fc 1000 Hz Gain inf dB Q 1", fallbackName: "x")
        XCTAssertEqual(parsed?.profile.bands.first?.gain, 0)
        XCTAssertNil(EqualizerProfileText.parse("Preamp: nan dB", fallbackName: "x"))
    }

    func testClampingTurnsANaNBandIntoAUsableOne() {
        let band = EqualizerBand(type: .bell, frequency: .nan, gain: .infinity, q: .nan).clamped()
        XCTAssertTrue(band.frequency.isFinite && band.gain.isFinite && band.q.isFinite)
        XCTAssertEqual(band.gain, 0)
    }

    func testAGraphicProfileRoundTripsExactly() throws {
        let original = EqualizerPresets.profile(forKey: "rock")!

        let text = EqualizerProfileText.write(original)
        let parsed = try XCTUnwrap(EqualizerProfileText.parse(text, fallbackName: "other"))

        XCTAssertEqual(parsed.profile.kind, .graphic)
        XCTAssertEqual(parsed.profile.targets, original.targets)
        XCTAssertEqual(parsed.profile.name, "Rock")
        XCTAssertTrue(parsed.profile.isAutoPreamp)
    }

    func testAParametricProfileRoundTripsExactly() throws {
        let original = EqualizerProfile.parametric(
            name: "Warm",
            bands: [
                EqualizerBand(type: .highPass, frequency: 28, q: 0.71),
                EqualizerBand(type: .lowShelf, frequency: 95, gain: 3.5, q: 0.71),
                EqualizerBand(type: .bell, frequency: 3_300, gain: 2.6, q: 1.4),
            ]
        )

        let parsed = try XCTUnwrap(EqualizerProfileText.parse(EqualizerProfileText.write(original), fallbackName: "x"))

        XCTAssertEqual(parsed.profile.bands, original.bands)
        XCTAssertEqual(parsed.profile.name, "Warm")
    }

    func testTheWrittenTextIsTheSameOnEveryClient() {
        let profile = EqualizerProfile.parametric(
            name: "Sample",
            bands: [EqualizerBand(type: .bell, frequency: 1_000, gain: 6, q: 1.41)]
        )

        XCTAssertEqual(
            EqualizerProfileText.write(profile),
            "# Flaccy Equalizer: Sample\nPreamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.41\n"
        )
    }
}
