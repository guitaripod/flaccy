import XCTest
@testable import FlaccyCore

final class ArtworkFramingTests: XCTestCase {

    private func framing(_ width: Double, _ height: Double, side: Double = 400) -> ArtworkFraming {
        ArtworkFraming(imageWidth: width, imageHeight: height, frameSide: side)!
    }

    func testF1FreshFramingFillsAndCentres() {
        let f = framing(3000, 2000)
        XCTAssertEqual(f.zoom, 0.2, accuracy: 1e-12)
        XCTAssertEqual(f.fillZoom, 0.2, accuracy: 1e-12)
        XCTAssertEqual(f.visibleSide, 2000, accuracy: 1e-9)
        XCTAssertEqual(f.centerX, 1500, accuracy: 1e-9)
        XCTAssertEqual(f.centerY, 1000, accuracy: 1e-9)
        XCTAssertTrue(f.isAtFill)
    }

    func testF2UnusableSizesYieldNoFraming() {
        XCTAssertNil(ArtworkFraming(imageWidth: 0, imageHeight: 100, frameSide: 400))
        XCTAssertNil(ArtworkFraming(imageWidth: 100, imageHeight: 100, frameSide: 0))
        XCTAssertNil(ArtworkFraming(imageWidth: .nan, imageHeight: 100, frameSide: 400))
    }

    func testF3MaximumZoomIsFiveTimesFillWithAOnePixelFloor() {
        XCTAssertEqual(framing(3000, 3000).maxZoom, 1.0, accuracy: 1e-12)
        XCTAssertEqual(framing(1000, 1000).maxZoom, 2.0, accuracy: 1e-12)
        XCTAssertEqual(framing(100, 100).maxZoom, 20.0, accuracy: 1e-12)
    }

    func testF4PanFollowsTheDragAndStopsAtTheImageEdge() {
        let f = framing(3000, 2000).panned(dx: -100, dy: 0)
        XCTAssertEqual(f.centerX, 1500 + 500, accuracy: 1e-9)
        XCTAssertEqual(f.centerY, 1000, accuracy: 1e-9)
        let edge = f.panned(dx: -100_000, dy: 0)
        XCTAssertEqual(edge.centerX, 2000, accuracy: 1e-9)
        let other = f.panned(dx: 100_000, dy: 0)
        XCTAssertEqual(other.centerX, 1000, accuracy: 1e-9)
    }

    func testF5ThePanAxisOfASquareFillHasNoSlack() {
        let f = framing(2000, 2000).panned(dx: 300, dy: -300)
        XCTAssertEqual(f.centerX, 1000, accuracy: 1e-9)
        XCTAssertEqual(f.centerY, 1000, accuracy: 1e-9)
    }

    func testF6ZoomKeepsThePointUnderTheAnchorFixed() {
        let start = framing(3000, 3000)
        let anchorX = 100.0, anchorY = 300.0
        let before = (
            x: start.centerX + (anchorX - 200) / start.zoom,
            y: start.centerY + (anchorY - 200) / start.zoom
        )
        let zoomed = start.zoomed(to: 0.5, anchorX: anchorX, anchorY: anchorY)
        let after = (
            x: zoomed.centerX + (anchorX - 200) / zoomed.zoom,
            y: zoomed.centerY + (anchorY - 200) / zoomed.zoom
        )
        XCTAssertEqual(zoomed.zoom, 0.5, accuracy: 1e-12)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
    }

    func testF7ZoomIsClampedBetweenFillAndMaximum() {
        let f = framing(2000, 2000)
        XCTAssertEqual(f.zoomed(to: 0.0001).zoom, f.fillZoom, accuracy: 1e-12)
        XCTAssertEqual(f.zoomed(to: 1000).zoom, f.maxZoom, accuracy: 1e-12)
        XCTAssertEqual(f.zoomed(byFactor: 0).zoom, f.zoom, accuracy: 1e-12)
    }

    func testF8ZoomedToCornerStaysInsideTheImage() {
        let f = framing(2000, 2000).zoomed(to: 1.0, anchorX: 0, anchorY: 0)
        XCTAssertGreaterThanOrEqual(f.visibleX, -1e-9)
        XCTAssertGreaterThanOrEqual(f.visibleY, -1e-9)
        XCTAssertLessThanOrEqual(f.visibleX + f.visibleSide, 2000 + 1e-9)
    }

    func testF9DoubleClickZoomsInThenBackOut() {
        let f = framing(2000, 2000)
        let into = f.toggled(anchorX: 200, anchorY: 200)
        XCTAssertEqual(into.zoom, f.fillZoom * 2.5, accuracy: 1e-12)
        XCTAssertFalse(into.isAtFill)
        let out = into.toggled(anchorX: 200, anchorY: 200)
        XCTAssertEqual(out.zoom, f.fillZoom, accuracy: 1e-12)
        XCTAssertTrue(out.isAtFill)
    }

    func testF10ZoomFractionRunsLogarithmicallyFromZeroToOne() {
        let f = framing(2000, 2000)
        XCTAssertEqual(f.zoomFraction, 0, accuracy: 1e-12)
        XCTAssertEqual(f.zoomed(toFraction: 1).zoomFraction, 1, accuracy: 1e-12)
        let half = f.zoomed(toFraction: 0.5)
        XCTAssertEqual(half.zoom, f.fillZoom * pow(f.maxZoom / f.fillZoom, 0.5), accuracy: 1e-9)
        XCTAssertEqual(half.zoomFraction, 0.5, accuracy: 1e-9)
    }

    func testF11ResizingKeepsWhatShowed() {
        let zoomed = framing(2000, 2000, side: 400).zoomed(to: 0.6, anchorX: 50, anchorY: 50)
        let resized = zoomed.resized(frameSide: 200)
        XCTAssertEqual(resized.visibleSide, zoomed.visibleSide, accuracy: 1e-9)
        XCTAssertEqual(resized.centerX, zoomed.centerX, accuracy: 1e-9)
        XCTAssertEqual(resized.centerY, zoomed.centerY, accuracy: 1e-9)
    }

    func testF12OutputIsCappedAtTheLimitAndByTheSource() {
        let f = framing(3000, 3000)
        XCTAssertEqual(f.outputPixels(limit: 1600), 1600)
        XCTAssertEqual(framing(900, 900).outputPixels(limit: 1600), 900)
        XCTAssertEqual(f.zoomed(to: 1.0).outputPixels(limit: 1600), 400)
    }

    func testF13TallImagesFillOnTheirNarrowEdge() {
        let f = framing(1000, 4000)
        XCTAssertEqual(f.fillZoom, 0.4, accuracy: 1e-12)
        XCTAssertEqual(f.visibleSide, 1000, accuracy: 1e-9)
        let panned = f.panned(dx: 0, dy: -100_000)
        XCTAssertEqual(panned.centerY, 4000 - 500, accuracy: 1e-9)
        XCTAssertEqual(panned.centerX, 500, accuracy: 1e-9)
    }

    func testF14AFramingIsSoftWhenFewerThanFiveHundredPixelsShow() {
        XCTAssertFalse(framing(1000, 1000).isSoft)
        XCTAssertTrue(framing(400, 400).isSoft)
        XCTAssertTrue(framing(3000, 3000).zoomed(to: 1.0).isSoft)
        XCTAssertFalse(framing(500, 500).isSoft)
    }
}
