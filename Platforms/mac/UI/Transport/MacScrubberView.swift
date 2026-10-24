import AppKit

/// Timeline scrubber: capsule track that thickens on hover, a floating time
/// tooltip under the pointer, click-anywhere positioning, and continuous
/// drag reporting for chase-seeking. External progress updates are ignored
/// while the user is scrubbing so the knob never fights the pointer.
final class MacScrubberView: NSView {

    /// The compact variant sits in the main transport bar; the prominent one is
    /// the Now Playing timeline, with a thicker track, a visible playhead dot
    /// and a taller hit area so it reads as the hero control of the immersive
    /// view rather than a hairline progress indicator.
    enum Style {
        case compact
        case prominent
    }

    var onScrub: ((TimeInterval) -> Void)?
    var onCommit: ((TimeInterval) -> Void)?

    var style: Style = .compact {
        didSet {
            guard style != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private(set) var isScrubbing = false

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let thumbLayer = CALayer()
    private let hoverTimeLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var fraction: Double = 0
    private var duration: TimeInterval = 0

    private var idleThickness: CGFloat { style == .prominent ? 5 : 4 }
    private var hoverThickness: CGFloat { style == .prominent ? 9 : 7 }
    private var thumbRadius: CGFloat {
        guard style == .prominent else { return 0 }
        return isHovered || isScrubbing ? 6.5 : 4.5
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(thumbLayer)
        thumbLayer.shadowColor = NSColor.black.cgColor
        thumbLayer.shadowOpacity = 0.28
        thumbLayer.shadowRadius = 2.5
        thumbLayer.shadowOffset = CGSize(width: 0, height: -1)
        applyTrackColors()

        hoverTimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        hoverTimeLabel.textColor = .labelColor
        hoverTimeLabel.backgroundColor = .clear
        hoverTimeLabel.isBordered = false
        hoverTimeLabel.isEditable = false
        hoverTimeLabel.wantsLayer = true
        hoverTimeLabel.isHidden = true
        addSubview(hoverTimeLabel)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Playback position"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Layer background colors don't re-resolve on an appearance change, so
    /// resolve them within the current effective appearance and refresh whenever
    /// it flips — otherwise the track/fill stay stuck at their init-time color
    /// (invisible in the dark immersive player, wrong in light mode).
    private func applyTrackColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.28).cgColor
            fillLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.9).cgColor
            thumbLayer.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTrackColors()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: style == .prominent ? 26 : 18)
    }

    func setProgress(current: TimeInterval, duration: TimeInterval) {
        self.duration = duration
        setAccessibilityValue(Self.format(current))
        guard !isScrubbing else { return }
        fraction = duration > 0 ? min(1, max(0, current / duration)) : 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let thickness = isHovered || isScrubbing ? hoverThickness : idleThickness
        let radius = thumbRadius
        let trackWidth = max(0, bounds.width - radius * 2)
        let trackRect = NSRect(
            x: radius, y: (bounds.height - thickness) / 2, width: trackWidth, height: thickness
        )
        let fillWidth = trackWidth * CGFloat(fraction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = trackRect
        trackLayer.cornerRadius = thickness / 2
        fillLayer.frame = NSRect(
            x: radius, y: trackRect.minY, width: fillWidth, height: thickness
        )
        fillLayer.cornerRadius = thickness / 2
        thumbLayer.frame = NSRect(
            x: fillWidth, y: (bounds.height - radius * 2) / 2,
            width: radius * 2, height: radius * 2
        )
        thumbLayer.cornerRadius = radius
        thumbLayer.isHidden = radius == 0 || duration <= 0
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard duration > 0 else { return }
        isHovered = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverTimeLabel.isHidden = true
        needsLayout = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard duration > 0, isHovered else { return }
        updateHoverTooltip(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        isScrubbing = true
        needsLayout = true
        applyPointer(event, commit: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        applyPointer(event, commit: false)
        updateHoverTooltip(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        applyPointer(event, commit: true)
        isScrubbing = false
        needsLayout = true
    }

    /// Ends a scrub without emitting, used when the track changes mid-gesture.
    func abortScrub() {
        isScrubbing = false
        hoverTimeLabel.isHidden = true
        needsLayout = true
    }

    private func applyPointer(_ event: NSEvent, commit: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        fraction = bounds.width > 0 ? min(1, max(0, Double(x / bounds.width))) : 0
        needsLayout = true
        let time = fraction * duration
        if commit {
            onCommit?(time)
        } else {
            onScrub?(time)
        }
    }

    private func updateHoverTooltip(for event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let hoverFraction = bounds.width > 0 ? min(1, max(0, Double(x / bounds.width))) : 0
        hoverTimeLabel.stringValue = Self.format(hoverFraction * duration)
        hoverTimeLabel.sizeToFit()
        let labelX = min(
            max(0, x - hoverTimeLabel.frame.width / 2),
            bounds.width - hoverTimeLabel.frame.width
        )
        hoverTimeLabel.setFrameOrigin(NSPoint(x: labelX, y: bounds.height - 2))
        hoverTimeLabel.isHidden = false
    }

    private static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
