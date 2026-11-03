import FlaccyCore
import XCTest

final class SongGainTests: XCTestCase {

    func testLevelsStayInsideTheControlsRange() {
        XCTAssertEqual(SongGain.clamped(130), 120)
        XCTAssertEqual(SongGain.clamped(-500), -120)
        XCTAssertEqual(SongGain.clamped(35), 35)
        XCTAssertEqual(SongGain.fromServer(240), 120)
        XCTAssertEqual(SongGain.fromServer(-240), -120)
        XCTAssertEqual(SongGain.fromServer(-37), -37)
    }

    func testSliderPositionsSnapToHalfDecibelSteps() {
        XCTAssertEqual(SongGain.snapped(decibels: 3.24), 30)
        XCTAssertEqual(SongGain.snapped(decibels: 3.26), 35)
        XCTAssertEqual(SongGain.snapped(decibels: -0.2), 0)
        XCTAssertEqual(SongGain.snapped(decibels: -7.8), -80)
        XCTAssertEqual(SongGain.snapped(decibels: 40), 120)
        XCTAssertEqual(SongGain.snapped(decibels: .nan), 0)
    }

    func testStepsLandOnTheGridWithoutSkippingOne() {
        XCTAssertEqual(SongGain.stepped(0, by: 1), 5)
        XCTAssertEqual(SongGain.stepped(0, by: -1), -5)
        XCTAssertEqual(SongGain.stepped(37, by: 1), 40)
        XCTAssertEqual(SongGain.stepped(37, by: -1), 35)
        XCTAssertEqual(SongGain.stepped(-37, by: 1), -35)
        XCTAssertEqual(SongGain.stepped(-37, by: -1), -40)
        XCTAssertEqual(SongGain.stepped(115, by: 2), 120)
        XCTAssertEqual(SongGain.stepped(-120, by: -1), -120)
        XCTAssertEqual(SongGain.stepped(20, by: 0), 20)
    }

    func testTheLevelFoldsIntoThePreampAndRaisingAlwaysGuards() {
        let bell = EqualizerBand(type: .bell, frequency: 1_000, gain: 3, q: 1)
        let flat = SongGain.stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: false, tenths: 0)
        XCTAssertEqual(flat, SongGain.Stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: false))

        let raised = SongGain.stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: false, tenths: 35)
        XCTAssertEqual(raised, SongGain.Stage(isEngaged: true, bands: [], preampDecibels: 3.5, peakGuard: true))

        let lowered = SongGain.stage(isEngaged: true, bands: [bell], preampDecibels: -3.1, peakGuard: false, tenths: -20)
        XCTAssertEqual(lowered, SongGain.Stage(isEngaged: true, bands: [bell], preampDecibels: -5.1, peakGuard: false))

        let beyond = SongGain.stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: true, tenths: 400)
        XCTAssertEqual(beyond.preampDecibels, 12)
    }

    func testLabelsUseTheLocaleAndATrueMinus() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(SongGain.label(35, locale: english), "+3.5 dB")
        XCTAssertEqual(SongGain.label(-20, locale: english), "\u{2212}2 dB")
        XCTAssertEqual(SongGain.label(0, locale: english), "0 dB")
        XCTAssertEqual(SongGain.label(120, locale: english), "+12 dB")
        XCTAssertEqual(SongGain.label(35, locale: Locale(identifier: "de_DE")), "+3,5 dB")
    }

    func testARaisedSongComesUpByItsLevelInTheKernel() {
        let stage = SongGain.stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: false, tenths: 60)
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: 44_100)
        kernel.configure(bands: stage.bands, preampDecibels: stage.preampDecibels, isEngaged: stage.isEngaged, peakGuard: stage.peakGuard, startsEngaged: true)
        var samples = [Float](repeating: 0.1, count: 512)
        run(kernel, over: &samples)
        XCTAssertEqual(Double(samples[511]), 0.1 * pow(10, 6.0 / 20), accuracy: 1e-5)
    }

    func testARaisedSongNeverLeavesTheKernelAboveFullScale() {
        let stage = SongGain.stage(isEngaged: false, bands: [], preampDecibels: 0, peakGuard: false, tenths: 120)
        let kernel = EqualizerKernel(channelCount: 1, sampleRate: 44_100)
        kernel.configure(bands: stage.bands, preampDecibels: stage.preampDecibels, isEngaged: stage.isEngaged, peakGuard: stage.peakGuard, startsEngaged: true)
        var samples = (0..<4_096).map { Float(0.9 * sin(Double($0) * 2 * .pi * 220 / 44_100)) }
        run(kernel, over: &samples)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0001)
        XCTAssertTrue(kernel.guardReduced)
    }

    private func run(_ kernel: EqualizerKernel, over samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { buffer in
            let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
            defer { planes.deallocate() }
            planes[0] = buffer.baseAddress!
            kernel.process(planes: planes, planeStride: 1, frames: count)
        }
    }
}
