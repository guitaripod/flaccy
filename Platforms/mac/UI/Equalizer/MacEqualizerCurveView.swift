import AppKit
import FlaccyCore

@MainActor
protocol MacEqualizerCurveViewDelegate: EqualizerPlotInteractionDelegate {
    func curveView(_ view: MacEqualizerCurveView, scaleQBy factor: Double, at index: Int)
    func curveView(_ view: MacEqualizerCurveView, stepGainBy delta: Double, at index: Int)
    func curveView(_ view: MacEqualizerCurveView, selectBandBy offset: Int)
    func curveViewDeleteSelectedBand(_ view: MacEqualizerCurveView)
    func curveViewBeginCompare(_ view: MacEqualizerCurveView)
    func curveViewEndCompare(_ view: MacEqualizerCurveView)
}

/// The response curve on the Mac. Drawing, geometry and the editing rules are
/// the same code the iPhone runs (`EqualizerPlotRenderer`, `EqualizerPlotModel`,
/// `EqualizerPlotInteraction`); this view adds what a pointer and a keyboard
/// bring: arrows to move between bands and nudge gain (shift 2 dB, option
/// 0.1 dB), 0 to reset a band, delete to remove one, C held to compare, and the
/// scroll wheel over the curve for Q in Advanced mode.
final class MacEqualizerCurveView: NSView {

    typealias Content = EqualizerCurveContent

    weak var delegate: MacEqualizerCurveViewDelegate? {
        didSet { interaction.delegate = delegate }
    }
    var spectrumProvider: (() -> [Float]?)?
    var onFrame: (() -> Void)?

    private(set) var content = Content()

    private let model = EqualizerPlotModel()
    private lazy var interaction = EqualizerPlotInteraction(model: model)
    private let plotInsets = NSEdgeInsets(top: 20, left: 48, bottom: 40, right: 18)
    private var ticker: Timer?
    private var accessibilityBands: [MacEqualizerBandElement] = []
    private var isComparingWithKey = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Equalizer response curve"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        ticker?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate()
        ticker = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func update(_ newContent: Content, animated: Bool) {
        content = newContent
        model.update(newContent.plot, snap: !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        rebuildAccessibility()
        needsDisplay = true
    }

    func setPreview(_ bands: [EqualizerBand]?) {
        model.setPreview(bands, snap: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        needsDisplay = true
    }

    var isPreviewing: Bool {
        model.isPreviewing
    }

    private var plot: CGRect {
        CGRect(
            x: plotInsets.left,
            y: plotInsets.top,
            width: max(bounds.width - plotInsets.left - plotInsets.right, 10),
            height: max(bounds.height - plotInsets.top - plotInsets.bottom, 10)
        )
    }

    @objc private func tick() {
        guard window?.isVisible == true else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.step(spectrum: spectrumProvider?(), freezeSpectrum: spectrumProvider == nil || reduceMotion)
        onFrame?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let style = EqualizerPlotRenderer.Style(
            accent: content.accent.cgColor,
            cut: EqualizerTheme.cut.cgColor,
            bandColors: EqualizerTheme.bandColors.map(\.cgColor),
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            isEnabled: content.isEnabled,
            isComparing: content.isComparing
        )
        EqualizerPlotRenderer.draw(in: context, bounds: bounds, plot: plot, model: model, style: style, preview: model.previewPoints(in: plot))
        if window?.firstResponder === self, let ring = focusRingRect() {
            context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            context.setLineWidth(2)
            context.addPath(CGPath(roundedRect: ring, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
        }
    }

    private func focusRingRect() -> CGRect? {
        guard (0..<model.nodeCount).contains(content.selectedIndex) else { return nil }
        let center = model.nodePosition(content.selectedIndex, in: plot)
        return CGRect(x: center.x - 18, y: plot.minY - 4, width: 36, height: plot.height + 8)
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(plot, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        interaction.begin(at: point, in: plot, time: event.timestamp)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        interaction.move(to: convert(event.locationInWindow, from: nil), in: plot)
    }

    override func mouseUp(with event: NSEvent) {
        interaction.end()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard content.selectedIndex < model.nodeCount else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 14 : event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        switch model.content.mode {
        case .advanced:
            delegate?.curveView(self, scaleQBy: pow(2, Double(-delta) / 10), at: content.selectedIndex)
        case .simple:
            delegate?.curveView(self, stepGainBy: Double(delta > 0 ? 0.5 : -0.5), at: content.selectedIndex)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
        guard !flags.contains(.command), !flags.contains(.control) else {
            super.keyDown(with: event)
            return
        }
        let step: Double = flags.contains(.shift) ? 2 : (flags.contains(.option) ? 0.1 : 0.5)
        switch event.keyCode {
        case 123: delegate?.curveView(self, selectBandBy: -1)
        case 124: delegate?.curveView(self, selectBandBy: 1)
        case 126: nudge(step)
        case 125: nudge(-step)
        case 51, 117: delegate?.curveViewDeleteSelectedBand(self)
        default:
            switch event.charactersIgnoringModifiers {
            case "0": delegate?.interaction(resetBandAt: content.selectedIndex)
            case "c", "C":
                guard !isComparingWithKey else { return }
                isComparingWithKey = true
                delegate?.curveViewBeginCompare(self)
            default: super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if isComparingWithKey, event.charactersIgnoringModifiers?.lowercased() == "c" {
            isComparingWithKey = false
            delegate?.curveViewEndCompare(self)
        } else {
            super.keyUp(with: event)
        }
    }

    private func nudge(_ delta: Double) {
        guard content.selectedIndex < model.nodeCount else { return }
        delegate?.curveView(self, stepGainBy: delta, at: content.selectedIndex)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        accessibilityBands = (0..<model.nodeCount).map { index in
            let element = MacEqualizerBandElement()
            element.owner = self
            element.bandIndex = index
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.slider)
            let frequency = model.content.mode == .simple ? GraphicSolver.centres[index] : content.bands[index].frequency
            element.setAccessibilityLabel(EqualizerCopy.hertz(frequency))
            let value: String
            if model.content.mode == .simple {
                value = "\(EqualizerCopy.decibels(content.targets[index])) dB"
            } else {
                let band = content.bands[index]
                value = band.type.hasGain ? "\(EqualizerCopy.decibels(band.gain)) dB" : EqualizerCopy.typeName(band.type)
            }
            element.setAccessibilityValue(value)
            return element
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let plot = plot
        for element in accessibilityBands where element.bandIndex < model.nodeCount {
            let center = model.nodePosition(element.bandIndex, in: plot)
            let rect = CGRect(x: center.x - 14, y: plot.minY, width: 28, height: plot.height)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
        }
        return accessibilityBands
    }

    fileprivate func stepBand(_ index: Int, by delta: Double) {
        delegate?.interaction(didBeginEditing: index)
        delegate?.curveView(self, stepGainBy: delta, at: index)
        delegate?.interactionDidEnd()
    }
}

private nonisolated final class MacEqualizerBandElement: NSAccessibilityElement {
    /// Set when the curve view builds its elements and read by the accessibility callbacks, which AppKit delivers on
    /// the main thread.
    nonisolated(unsafe) weak var owner: MacEqualizerCurveView?
    /// Set with `owner` and read by the same callbacks.
    nonisolated(unsafe) var bandIndex = 0

    override func accessibilityPerformIncrement() -> Bool {
        step(by: 1)
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(by: -1)
    }

    private func step(by delta: Double) -> Bool {
        let owner = owner
        let band = bandIndex
        MainActor.assumeIsolated { owner?.stepBand(band, by: delta) }
        return true
    }
}
