import FlaccyCore
import XCTest
@testable import flaccy

/// Mirrored by the tests in `linux/shared/src/equalizer/interaction.rs` and
/// `plot_model.rs`: the same presses and drags give the same actions, and the
/// plot model eases and settles the same way.
nonisolated final class EqualizerPlotInteractionTests: XCTestCase {

    private let plot = CGRect(x: 36, y: 18, width: 300, height: 200)

    private final class Recorder: EqualizerPlotInteractionDelegate {
        enum Event: Equatable {
            case begin(Int)
            case target(Double, Int)
            case move(Double, Double, Int)
            case reset(Int)
            case add(Double, Double)
            case detent(EqualizerDetent)
            case end
        }

        var events: [Event] = []

        func interaction(didBeginEditing index: Int) { events.append(.begin(index)) }
        func interaction(setTarget value: Double, at index: Int) { events.append(.target(value, index)) }
        func interaction(setFrequency frequency: Double, gain: Double, at index: Int) { events.append(.move(frequency, gain, index)) }
        func interaction(resetBandAt index: Int) { events.append(.reset(index)) }
        func interaction(addBandAtFrequency frequency: Double, gain: Double) { events.append(.add(frequency, gain)) }
        func interaction(didCross detent: EqualizerDetent) { events.append(.detent(detent)) }
        func interactionDidEnd() { events.append(.end) }
    }

    @MainActor private func column(_ index: Int) -> CGFloat {
        plot.minX + CGFloat(EqualizerPlot.x(forFrequency: GraphicSolver.centres[index], width: Double(plot.width)))
    }

    @MainActor private func y(_ decibels: Double) -> CGFloat {
        plot.minY + CGFloat(EqualizerPlot.y(forDecibels: decibels, height: Double(plot.height)))
    }

    @MainActor private func makeSimple() -> (EqualizerPlotModel, EqualizerPlotInteraction, Recorder) {
        let model = EqualizerPlotModel()
        model.update(EqualizerPlotContent(), snap: true)
        let interaction = EqualizerPlotInteraction(model: model)
        let recorder = Recorder()
        interaction.delegate = recorder
        return (model, interaction, recorder)
    }

    @MainActor private func makeAdvanced(_ bands: [EqualizerBand]) -> (EqualizerPlotModel, EqualizerPlotInteraction, Recorder) {
        let model = EqualizerPlotModel()
        var content = EqualizerPlotContent()
        content.mode = .advanced
        content.bands = bands
        model.update(content, snap: true)
        let interaction = EqualizerPlotInteraction(model: model)
        let recorder = Recorder()
        interaction.delegate = recorder
        return (model, interaction, recorder)
    }

    @MainActor func testPressingAColumnGrabsItAndSetsItsGainFromTheHeight() {
        let (model, interaction, recorder) = makeSimple()

        interaction.begin(at: CGPoint(x: column(3) + 4, y: y(6.1)), in: plot, time: 1)

        XCTAssertEqual(recorder.events, [.begin(3), .target(6, 3)])
        XCTAssertTrue(interaction.isActive)
        XCTAssertTrue(model.isDragging)
    }

    @MainActor func testDraggingKeepsTheBandItGrabbedAndMarksTheDetents() {
        let (_, interaction, recorder) = makeSimple()
        interaction.begin(at: CGPoint(x: column(5), y: y(2)), in: plot, time: 1)
        recorder.events.removeAll()

        interaction.move(to: CGPoint(x: column(9), y: y(3.2)), in: plot)
        interaction.move(to: CGPoint(x: column(9), y: y(0.1)), in: plot)
        interaction.move(to: CGPoint(x: column(9), y: y(11.9)), in: plot)

        XCTAssertEqual(recorder.events, [
            .detent(.tick), .target(3, 5),
            .detent(.zero), .target(0, 5),
            .detent(.limit), .target(12, 5),
        ])
    }

    @MainActor func testAMoveThatChangesNothingSaysNothing() {
        let (_, interaction, recorder) = makeSimple()
        interaction.begin(at: CGPoint(x: column(2), y: y(4)), in: plot, time: 1)
        recorder.events.removeAll()

        interaction.move(to: CGPoint(x: column(2), y: y(4.1)), in: plot)

        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor func testADoublePressOnAColumnResetsItInsteadOfDragging() {
        let (_, interaction, recorder) = makeSimple()
        let point = CGPoint(x: column(4), y: y(5))
        interaction.begin(at: point, in: plot, time: 1)
        interaction.end()
        recorder.events.removeAll()

        interaction.begin(at: point, in: plot, time: 1.2)

        XCTAssertEqual(recorder.events, [.begin(4), .detent(.reset), .reset(4)])
        XCTAssertFalse(interaction.isActive)
    }

    @MainActor func testTwoPressesTooFarApartInTimeAreNotADouble() {
        let (_, interaction, recorder) = makeSimple()
        let point = CGPoint(x: column(4), y: y(5))
        interaction.begin(at: point, in: plot, time: 1)
        interaction.end()
        recorder.events.removeAll()

        interaction.begin(at: point, in: plot, time: 1.5)

        XCTAssertEqual(recorder.events, [.begin(4), .target(5, 4)])
    }

    @MainActor func testEndingReportsOnceAndClearsTheDraggingFlag() {
        let (model, interaction, recorder) = makeSimple()
        interaction.begin(at: CGPoint(x: column(0), y: y(1)), in: plot, time: 1)
        recorder.events.removeAll()

        interaction.end()
        interaction.end()

        XCTAssertEqual(recorder.events, [.end])
        XCTAssertFalse(model.isDragging)
    }

    @MainActor func testInAdvancedAPressOnANodeDragsBothAxesToRoundedValues() {
        let band = EqualizerBand(type: .bell, frequency: 1_000, gain: 3, q: 1)
        let (model, interaction, recorder) = makeAdvanced([band])
        let node = model.nodePosition(0, in: plot)

        interaction.begin(at: node, in: plot, time: 1)
        interaction.move(
            to: CGPoint(x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: 2_003, width: Double(plot.width))), y: y(-2.34)),
            in: plot
        )

        XCTAssertEqual(recorder.events.first, .begin(0))
        guard case let .move(frequency, gain, index)? = recorder.events.last else { return XCTFail("expected a move") }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(frequency, 2_000, accuracy: 1e-9)
        XCTAssertEqual(gain, -2.3, accuracy: 1e-9)
    }

    @MainActor func testInAdvancedAPassFilterMovesSidewaysOnly() {
        let band = EqualizerBand(type: .highPass, frequency: 80)
        let (model, interaction, recorder) = makeAdvanced([band])
        let node = model.nodePosition(0, in: plot)
        interaction.begin(at: node, in: plot, time: 1)
        recorder.events.removeAll()

        interaction.move(to: CGPoint(x: node.x + 40, y: y(8)), in: plot)

        guard case let .move(_, gain, _)? = recorder.events.last else { return XCTFail("expected a move") }
        XCTAssertEqual(gain, 0)
        XCTAssertFalse(recorder.events.contains { if case .detent = $0 { return true } else { return false } })
    }

    @MainActor func testInAdvancedADoublePressOnEmptySpaceAddsABandThere() {
        let (_, interaction, recorder) = makeAdvanced([EqualizerBand(type: .bell, frequency: 100)])
        let point = CGPoint(x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: 5_000, width: Double(plot.width))), y: y(4))
        interaction.begin(at: point, in: plot, time: 1)
        interaction.end()
        recorder.events.removeAll()

        interaction.begin(at: point, in: plot, time: 1.1)

        XCTAssertEqual(recorder.events.first, .detent(.add))
        guard case let .add(frequency, gain)? = recorder.events.last else { return XCTFail("expected a new band") }
        XCTAssertEqual(frequency, 5_000, accuracy: 60)
        XCTAssertEqual(gain, 4)
        XCTAssertTrue(interaction.isActive)
    }

    @MainActor func testInAdvancedADoublePressOnANodeResetsItsGain() {
        let (model, interaction, recorder) = makeAdvanced([EqualizerBand(type: .bell, frequency: 1_000, gain: 5, q: 1)])
        let node = model.nodePosition(0, in: plot)
        interaction.begin(at: node, in: plot, time: 1)
        interaction.end()
        recorder.events.removeAll()

        interaction.begin(at: node, in: plot, time: 1.15)

        XCTAssertEqual(recorder.events, [.begin(0), .detent(.reset), .reset(0)])
    }

    @MainActor func testInAdvancedASinglePressOnEmptySpaceDoesNothing() {
        let (_, interaction, recorder) = makeAdvanced([EqualizerBand(type: .bell, frequency: 100)])

        interaction.begin(
            at: CGPoint(x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: 9_000, width: Double(plot.width))), y: y(7)),
            in: plot,
            time: 1
        )

        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertFalse(interaction.isActive)
    }

    @MainActor func testDrawnTargetsGlideToNewOnesAndThenSettleExactly() {
        let model = EqualizerPlotModel()
        model.update(EqualizerPlotContent(), snap: true)
        var goal = EqualizerPlotContent()
        goal.targets = [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        model.update(goal, snap: false)

        XCTAssertEqual(model.displayTargets[0], 0)
        XCTAssertTrue(model.step(spectrum: nil, freezeSpectrum: true))
        XCTAssertGreaterThan(model.displayTargets[0], 0)
        XCTAssertLessThan(model.displayTargets[0], 6)
        for _ in 0..<40 { model.step(spectrum: nil, freezeSpectrum: true) }
        XCTAssertEqual(model.displayTargets, goal.targets)
        XCTAssertFalse(model.step(spectrum: nil, freezeSpectrum: true))
    }

    @MainActor func testWhileDraggingTheDrawnTargetsFollowAtOnce() {
        let model = EqualizerPlotModel()
        model.update(EqualizerPlotContent(), snap: true)
        model.isDragging = true
        var dragged = EqualizerPlotContent()
        dragged.targets[3] = 4.5
        model.update(dragged, snap: false)

        XCTAssertTrue(model.step(spectrum: nil, freezeSpectrum: true))
        XCTAssertEqual(model.displayTargets, dragged.targets)
    }

    @MainActor func testTheSpectrumRisesAtOnceAndFallsSlowly() {
        let model = EqualizerPlotModel()
        model.step(spectrum: [Float](repeating: -20, count: 110), freezeSpectrum: false)
        XCTAssertEqual(model.spectrumBins[0], -20)

        model.step(spectrum: [Float](repeating: -80, count: 110), freezeSpectrum: false)
        XCTAssertEqual(model.spectrumBins[0], -22.2, accuracy: 1e-4)

        model.step(spectrum: nil, freezeSpectrum: false)
        XCTAssertEqual(model.spectrumBins[0], -25.2, accuracy: 1e-4)
    }

    @MainActor func testAFrozenSpectrumDoesNotMove() {
        let model = EqualizerPlotModel()
        model.step(spectrum: [Float](repeating: -30, count: 110), freezeSpectrum: false)
        model.step(spectrum: [Float](repeating: -10, count: 110), freezeSpectrum: true)

        XCTAssertEqual(model.spectrumBins[5], -30)
    }
}
