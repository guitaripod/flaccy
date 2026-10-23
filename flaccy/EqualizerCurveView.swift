import Accessibility
import FlaccyCore
import UIKit

@MainActor
protocol EqualizerCurveViewDelegate: AnyObject {
    func curveView(_ view: EqualizerCurveView, didBeginEditing index: Int)
    func curveView(_ view: EqualizerCurveView, setTarget value: Double, at index: Int)
    func curveView(_ view: EqualizerCurveView, setFrequency frequency: Double, gain: Double, at index: Int)
    func curveView(_ view: EqualizerCurveView, scaleQBy factor: Double, at index: Int)
    func curveView(_ view: EqualizerCurveView, stepGainBy delta: Double, at index: Int)
    func curveView(_ view: EqualizerCurveView, resetBandAt index: Int)
    func curveView(_ view: EqualizerCurveView, addBandAtFrequency frequency: Double, gain: Double)
    func curveViewDidEndEditing(_ view: EqualizerCurveView)
}

/// The response curve on the iPhone: a log-frequency plot with the live
/// spectrum behind it, the curve in front, and a point for every band. The
/// geometry and the editing rules live in `EqualizerPlotModel` and
/// `EqualizerPlotInteraction`, shared with the Mac; this view draws, forwards
/// touches, adds the pinch that changes a band's Q, and provides the haptics
/// and the VoiceOver surface.
final class EqualizerCurveView: UIView {

    typealias Mode = EqualizerPlotMode

    typealias Content = EqualizerCurveContent

    weak var delegate: EqualizerCurveViewDelegate?
    var spectrumProvider: (() -> [Float]?)?
    var onFrame: (() -> Void)?

    private(set) var content = Content()

    private let model = EqualizerPlotModel()
    private lazy var interaction = EqualizerPlotInteraction(model: model)
    private let plotInsets = UIEdgeInsets(top: 18, left: 36, bottom: 38, right: 12)
    private let touchTracker = UILongPressGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private var displayLink: CADisplayLink?
    private var lastPinchScale: CGFloat = 1
    private var accessibilityBandElements: [UIAccessibilityElement] = []

    private let selectionHaptic = UISelectionFeedbackGenerator()
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let rigidHaptic = UIImpactFeedbackGenerator(style: .rigid)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isMultipleTouchEnabled = true
        interaction.delegate = self

        touchTracker.minimumPressDuration = 0
        touchTracker.allowableMovement = .greatestFiniteMagnitude
        touchTracker.addTarget(self, action: #selector(handleTouch(_:)))
        addGestureRecognizer(touchTracker)

        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        registerForTraitChanges([UITraitAccessibilityContrast.self, UITraitUserInterfaceStyle.self]) { (self: EqualizerCurveView, _) in
            self.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        displayLink?.invalidate()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 272)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func update(_ newContent: Content, animated: Bool = true) {
        content = newContent
        model.update(newContent.plot, snap: !animated || UIAccessibility.isReduceMotionEnabled)
        rebuildAccessibility()
        setNeedsDisplay()
    }

    func setPreview(_ bands: [EqualizerBand]?) {
        model.setPreview(bands, snap: UIAccessibility.isReduceMotionEnabled)
        setNeedsDisplay()
    }

    var isPreviewing: Bool {
        model.isPreviewing
    }

    private var plot: CGRect {
        bounds.inset(by: plotInsets)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 45, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let spectrum = spectrumProvider?()
        model.step(spectrum: spectrum, freezeSpectrum: spectrumProvider == nil || UIAccessibility.isReduceMotionEnabled)
        onFrame?()
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let style = EqualizerPlotRenderer.Style(
            accent: content.accent.cgColor,
            cut: EqualizerTheme.cut.cgColor,
            bandColors: EqualizerTheme.bandColors.map(\.cgColor),
            highContrast: traitCollection.accessibilityContrast == .high,
            isEnabled: content.isEnabled,
            isComparing: content.isComparing
        )
        EqualizerPlotRenderer.draw(in: context, bounds: bounds, plot: plot, model: model, style: style, preview: model.previewPoints(in: plot))
    }

    // MARK: Touch

    @objc private func handleTouch(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            selectionHaptic.prepare()
            interaction.begin(at: point, in: plot, time: ProcessInfo.processInfo.systemUptime)
            setNeedsDisplay()
        case .changed:
            interaction.move(to: point, in: plot)
        case .ended, .cancelled, .failed:
            interaction.end()
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard model.content.mode == .advanced, content.bands.indices.contains(content.selectedIndex) else { return }
        switch gesture.state {
        case .began:
            lastPinchScale = 1
        case .changed:
            let factor = Double(lastPinchScale / max(gesture.scale, 0.01))
            lastPinchScale = gesture.scale
            delegate?.curveView(self, scaleQBy: factor, at: content.selectedIndex)
        default:
            break
        }
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        let chart = EqualizerChartElement(accessibilityContainer: self)
        chart.accessibilityLabel = String(localized: "Equalizer response curve")
        chart.accessibilityFrameInContainerSpace = bounds
        chart.accessibilityChartDescriptor = makeChartDescriptor()

        var elements: [UIAccessibilityElement] = [chart]
        for index in 0..<model.nodeCount {
            let element = EqualizerBandElement(accessibilityContainer: self)
            let frequency: Double
            let value: String
            switch model.content.mode {
            case .simple:
                frequency = GraphicSolver.centres[index]
                value = String(localized: "\(EqualizerCopy.decibels(content.targets[index])) decibels")
            case .advanced:
                let band = content.bands[index]
                frequency = band.frequency
                value = band.type.hasGain
                    ? String(localized: "\(EqualizerCopy.decibels(band.gain)) decibels")
                    : EqualizerCopy.typeName(band.type)
            }
            element.accessibilityLabel = EqualizerCopy.hertz(frequency)
            element.accessibilityValue = value
            element.accessibilityTraits = .adjustable
            element.owner = self
            element.bandIndex = index
            elements.append(element)
        }
        accessibilityBandElements = elements
        accessibilityElements = elements
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let plot = plot
        for element in accessibilityBandElements.dropFirst().compactMap({ $0 as? EqualizerBandElement }) {
            guard element.bandIndex < model.nodeCount else { continue }
            let center = model.nodePosition(element.bandIndex, in: plot)
            element.accessibilityFrameInContainerSpace = CGRect(x: center.x - 22, y: plot.minY, width: 44, height: plot.height)
        }
        accessibilityBandElements.first?.accessibilityFrameInContainerSpace = bounds
    }

    private func makeChartDescriptor() -> AXChartDescriptor {
        let frequencies = BiquadMath.logFrequencies(count: 24)
        let levels = frequencies.map { BiquadMath.responseDecibels(model.resolvedBands, frequency: $0) }
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Frequency in hertz"),
            range: EqualizerBand.frequencyRange.lowerBound...EqualizerBand.frequencyRange.upperBound,
            gridlinePositions: [100, 1_000, 10_000],
            valueDescriptionProvider: { EqualizerCopy.hertz($0) }
        )
        xAxis.scaleType = .log10
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Gain in decibels"),
            range: -EqualizerPlot.decibelRange...EqualizerPlot.decibelRange,
            gridlinePositions: [-6, 0, 6],
            valueDescriptionProvider: { String(localized: "\(EqualizerCopy.decibels($0)) decibels") }
        )
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Equalizer curve"),
            isContinuous: true,
            dataPoints: zip(frequencies, levels).map { AXDataPoint(x: $0, y: $1) }
        )
        return AXChartDescriptor(
            title: String(localized: "Equalizer response curve"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }

    fileprivate func stepBand(_ index: Int, by delta: Double) {
        delegate?.curveView(self, didBeginEditing: index)
        delegate?.curveView(self, stepGainBy: delta, at: index)
        delegate?.curveViewDidEndEditing(self)
    }
}

extension EqualizerCurveView: EqualizerPlotInteractionDelegate {

    func interaction(didBeginEditing index: Int) {
        delegate?.curveView(self, didBeginEditing: index)
    }

    func interaction(setTarget value: Double, at index: Int) {
        delegate?.curveView(self, setTarget: value, at: index)
    }

    func interaction(setFrequency frequency: Double, gain: Double, at index: Int) {
        delegate?.curveView(self, setFrequency: frequency, gain: gain, at: index)
    }

    func interaction(resetBandAt index: Int) {
        delegate?.curveView(self, resetBandAt: index)
    }

    func interaction(addBandAtFrequency frequency: Double, gain: Double) {
        delegate?.curveView(self, addBandAtFrequency: frequency, gain: gain)
    }

    func interaction(didCross detent: EqualizerDetent) {
        switch detent {
        case .tick: selectionHaptic.selectionChanged()
        case .zero, .reset, .add: softHaptic.impactOccurred()
        case .limit: rigidHaptic.impactOccurred()
        }
    }

    func interactionDidEnd() {
        delegate?.curveViewDidEndEditing(self)
    }
}

extension EqualizerCurveView: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

private final class EqualizerChartElement: UIAccessibilityElement, AXChart {
    var accessibilityChartDescriptor: AXChartDescriptor?
}

private final class EqualizerBandElement: UIAccessibilityElement {
    weak var owner: EqualizerCurveView?
    var bandIndex = 0

    override func accessibilityIncrement() {
        owner?.stepBand(bandIndex, by: 1)
    }

    override func accessibilityDecrement() {
        owner?.stepBand(bandIndex, by: -1)
    }
}
