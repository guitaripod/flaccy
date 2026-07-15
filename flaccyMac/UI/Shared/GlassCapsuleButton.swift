import AppKit

/// A Liquid Glass capsule action button with hover brightening and press
/// dimming — the desktop stand-in for the iOS haptic capsule vocabulary.
final class GlassCapsuleButton: NSControl {

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private var host: NSView?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(title: String, symbolName: String?, prominent: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true

        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        var views: [NSView] = []
        if let symbolName {
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            iconView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            iconView.contentTintColor = .labelColor
            views.append(iconView)
        }
        views.append(label)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        let tint: NSColor? = prominent ? MacColors.fill(0.12) : nil
        let surface = MacLiquidGlass.surface(hosting: stack, cornerRadius: 16, tint: tint)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        host = surface

        highlightView.wantsLayer = true
        highlightView.layer?.backgroundColor = MacColors.fill(0.12).cgColor
        highlightView.layer?.cornerRadius = 16
        highlightView.layer?.cornerCurve = .continuous
        highlightView.alphaValue = 0
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        animateHighlight(to: 0.6)
    }

    override func mouseExited(with event: NSEvent) {
        animateHighlight(to: 0)
    }

    override func mouseDown(with event: NSEvent) {
        animateHighlight(to: 1)
    }

    override func mouseUp(with event: NSEvent) {
        animateHighlight(to: bounds.contains(convert(event.locationInWindow, from: nil)) ? 0.6 : 0)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func animateHighlight(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            highlightView.animator().alphaValue = alpha
        }
    }
}
