import AppKit

/// Borderless symbol button with the hover and pressed states that stand in
/// for haptics on the desktop: a soft circular highlight on hover, dimmed
/// while pressed, optional accent tint for latched toggles.
final class TransportButton: NSButton {

    private let highlightLayer = CALayer()
    private var isHovered = false

    var isProminent = false {
        didSet { refreshTint() }
    }

    var isActiveToggle = false {
        didSet { refreshTint() }
    }

    init(symbolName: String, pointSize: CGFloat, accessibilityLabel: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        wantsLayer = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        highlightLayer.opacity = 0
        layer?.insertSublayer(highlightLayer, at: 0)
        setSymbol(symbolName, pointSize: pointSize)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        translatesAutoresizingMaskIntoConstraints = false
        refreshTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ symbolName: String, pointSize: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: max(base.width + 12, 30), height: max(base.height + 10, 30))
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side
        )
        highlightLayer.cornerRadius = side / 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateHighlight(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateHighlight(visible: false)
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.6
        super.mouseDown(with: event)
        alphaValue = 1
    }

    private func animateHighlight(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            highlightLayer.opacity = visible ? 1 : 0
        }
    }

    private func refreshTint() {
        if isActiveToggle {
            contentTintColor = .controlAccentColor
        } else if isProminent {
            contentTintColor = .labelColor
        } else {
            contentTintColor = .secondaryLabelColor
        }
    }
}
