import FlaccyCore
import XCTest
@testable import flaccy

/// The plot model's preview glide and the conversion naming behind the
/// preset deck; `linux/src/ui/equalizer/curve.rs` and `linux/src/eq/engine.rs`
/// do the same on the Linux side.
nonisolated final class EqualizerAuditionTests: XCTestCase {

    private let plot = CGRect(x: 36, y: 18, width: 300, height: 200)
    private let bassBell = [EqualizerBand(type: .bell, frequency: 80, gain: 9, q: 1)]

    @MainActor func testNothingIsPreviewedUntilAskedTo() {
        let model = EqualizerPlotModel()
        XCTAssertFalse(model.isPreviewing)
        XCTAssertNil(model.previewPoints(in: plot))
    }

    @MainActor func testASnappedPreviewIsTheTargetCurveAtOnce() {
        let model = EqualizerPlotModel()
        model.setPreview(bassBell, snap: true)
        XCTAssertEqual(model.previewPoints(in: plot), model.curvePoints(bassBell, in: plot))
    }

    @MainActor func testAGlidingPreviewStartsOnTheCurveInForceAndArrivesOnTheTarget() {
        let model = EqualizerPlotModel()
        model.setPreview(bassBell, snap: false)
        let start = model.previewPoints(in: plot)
        XCTAssertEqual(start, model.curvePoints([], in: plot))
        var frames = 0
        while model.step(spectrum: nil, freezeSpectrum: true), frames < 60 { frames += 1 }
        XCTAssertEqual(model.previewPoints(in: plot), model.curvePoints(bassBell, in: plot))
        XCTAssertLessThan(frames, 12)
    }

    @MainActor func testEndingAPreviewGoesBackToTheCurveInForce() {
        let model = EqualizerPlotModel()
        model.setPreview(bassBell, snap: true)
        model.setPreview(nil, snap: true)
        XCTAssertFalse(model.isPreviewing)
        XCTAssertNil(model.previewPoints(in: plot))
    }

    @MainActor func testConversionSuffixesCollapseToTheNameTheyStartedFrom() {
        XCTAssertEqual(EqualizerCopy.baseName(of: "Flat"), "Flat")
        XCTAssertEqual(EqualizerCopy.baseName(of: "Flat (Advanced)"), "Flat")
        XCTAssertEqual(EqualizerCopy.baseName(of: "Flat (Advanced) (Simple) (Advanced)"), "Flat")
        XCTAssertEqual(EqualizerCopy.baseName(of: "(Advanced)"), "(Advanced)")
    }
}
