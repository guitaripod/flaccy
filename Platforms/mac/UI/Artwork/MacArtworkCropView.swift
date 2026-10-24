import AppKit
import FlaccyCore

/// The square window a person composes a cover through. Every gesture — drag,
/// trackpad scroll, wheel, pinch, double click, keys, the slider — is turned
/// into a call on `ArtworkFraming`, which owns the geometry and can never be
/// asked for empty space. Rule-of-thirds guides fade in while it is being
/// worked and out again shortly after.
final class MacArtworkCropView: ArtworkFramedView {

    var onFramingChanged: ((Bool) -> Void)?

    private(set) var hasUserFraming = false

    private let guides = CAShapeLayer()
    private let dimLayer = CALayer()
    private let spinner = NSProgressIndicator()
    private let placeholder = NSImageView()
    private var hideGuides: DispatchWorkItem?
    private var isDragging = false
    private var dragOrigin = NSPoint.zero

    private static let arrowStep = 10.0
    private static let arrowShiftStep = 40.0
    private static let keyZoomFactor = 1.1

    var hasImage: Bool { image != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = 16
        focusRingType = .exterior

        guides.fillColor = nil
        guides.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        guides.lineWidth = 0.75
        guides.opacity = 0
        layer?.addSublayer(guides)

        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)

        placeholder.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        placeholder.symbolConfiguration = .init(pointSize: 56, weight: .ultraLight)
        placeholder.contentTintColor = MacColors.onArtwork(0.35)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Artwork preview"))
        setAccessibilityHelp(String(localized: "Drag to reposition, scroll to zoom, use the arrow keys to nudge"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSource(_ source: CGImage, userInitiated: Bool) {
        let side = max(bounds.width, 1)
        let fresh = ArtworkFraming(imageWidth: Double(source.width), imageHeight: Double(source.height), frameSide: side)
        hasUserFraming = userInitiated
        placeholder.isHidden = true
        show(source, framing: fresh)
        onFramingChanged?(false)
    }

    func setPlaceholderSymbol(_ name: String) {
        placeholder.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func setLoading(_ loading: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        dimLayer.opacity = loading ? 1 : 0
        CATransaction.commit()
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func fit() {
        guard let image, let fresh = ArtworkFraming(
            imageWidth: Double(image.width), imageHeight: Double(image.height), frameSide: framing?.frameSide ?? bounds.width
        ) else { return }
        apply(fresh, animated: true)
    }

    #if DEBUG
    func debugApply(_ framing: ArtworkFraming) {
        apply(framing, animated: false)
    }
    #endif

    func setZoomFraction(_ fraction: Double) {
        guard let framing else { return }
        apply(framing.zoomed(toFraction: fraction), animated: false)
    }

    func zoom(byFactor factor: Double) {
        guard let framing else { return }
        apply(framing.zoomed(byFactor: factor), animated: true)
    }

    func nudge(dx: Double, dy: Double) {
        guard let framing else { return }
        apply(framing.panned(dx: dx, dy: dy), animated: false)
    }

    override func layout() {
        super.layout()
        if let framing, bounds.width > 0, abs(framing.frameSide - bounds.width) > 0.01 {
            update(framing: framing.resized(frameSide: bounds.width), animated: false)
            onFramingChanged?(false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        guides.frame = bounds
        guides.path = Self.thirdsPath(in: bounds)
        CATransaction.commit()
    }

    private static func thirdsPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for step in 1...2 {
            let x = rect.width * CGFloat(step) / 3
            let y = rect.height * CGFloat(step) / 3
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }

    private func apply(_ next: ArtworkFraming, animated: Bool) {
        guard next != framing else { return }
        hasUserFraming = true
        update(framing: next, animated: animated)
        showGuides()
        onFramingChanged?(animated)
    }

    /// Screen points per point of this view, which differs from one while the
    /// interface is zoomed, so trackpad deltas land on the pixels under the
    /// fingers rather than moving at the zoom's speed.
    private var screenPointsPerPoint: Double {
        max(Double(convert(NSSize(width: 1, height: 1), to: nil).width), 0.01)
    }

    private func anchor(for event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let framing else { return }
        if event.clickCount == 2 {
            let point = anchor(for: event)
            apply(framing.toggled(anchorX: point.x, anchorY: point.y), animated: true)
            return
        }
        isDragging = true
        dragOrigin = anchor(for: event)
        NSCursor.closedHand.push()
        showGuides(holding: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let framing else { return }
        let point = anchor(for: event)
        apply(framing.panned(dx: point.x - dragOrigin.x, dy: point.y - dragOrigin.y), animated: false)
        dragOrigin = point
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        showGuides()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let framing else { return }
        let point = anchor(for: event)
        let panning = event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option)
        if panning {
            let unit = screenPointsPerPoint
            apply(framing.panned(dx: event.scrollingDeltaX / unit, dy: event.scrollingDeltaY / unit), animated: false)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.008 : event.deltaY * 0.06
        apply(framing.zoomed(byFactor: exp(delta), anchorX: point.x, anchorY: point.y), animated: false)
    }

    override func magnify(with event: NSEvent) {
        guard let framing else { return }
        let point = anchor(for: event)
        apply(framing.zoomed(byFactor: 1 + event.magnification, anchorX: point.x, anchorY: point.y), animated: false)
    }

    override func keyDown(with event: NSEvent) {
        guard image != nil else { return super.keyDown(with: event) }
        let step = event.modifierFlags.contains(.shift) ? Self.arrowShiftStep : Self.arrowStep
        switch event.specialKey {
        case .leftArrow: nudge(dx: -step, dy: 0)
        case .rightArrow: nudge(dx: step, dy: 0)
        case .upArrow: nudge(dx: 0, dy: -step)
        case .downArrow: nudge(dx: 0, dy: step)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoom(byFactor: Self.keyZoomFactor)
            case "-", "_": zoom(byFactor: 1 / Self.keyZoomFactor)
            case "0": fit()
            default: super.keyDown(with: event)
            }
        }
    }

    override func resetCursorRects() {
        if image != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private func showGuides(holding: Bool = false) {
        hideGuides?.cancel()
        setGuides(visible: true, duration: 0.12)
        guard !holding else { return }
        let work = DispatchWorkItem { [weak self] in self?.setGuides(visible: false, duration: 0.3) }
        hideGuides = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func setGuides(visible: Bool, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration)
        guides.opacity = visible ? 1 : 0
        CATransaction.commit()
    }
}
