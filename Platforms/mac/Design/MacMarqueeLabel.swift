import AppKit

/// Single-line label that scrolls its overflowing text while the pointer
/// hovers it — the Music.app convention — and sits tail-truncated otherwise.
/// Scroll speed and gap match the iOS MarqueeLabel (30 pt/s, 48 pt gap).
final class MacMarqueeLabel: NSView {

    private let primaryLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let scrollContainer = NSView()
    private var isScrolling = false
    private var isHovered = false

    private static let gap: CGFloat = 48
    private static let pointsPerSecond: CGFloat = 30

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            primaryLabel.stringValue = text
            trailingLabel.stringValue = text
            toolTip = text
            stopScrolling()
            needsLayout = true
        }
    }

    var font: NSFont {
        get { primaryLabel.font ?? .systemFont(ofSize: NSFont.systemFontSize) }
        set {
            primaryLabel.font = newValue
            trailingLabel.font = newValue
            stopScrolling()
            needsLayout = true
        }
    }

    var textColor: NSColor {
        get { primaryLabel.textColor ?? .labelColor }
        set {
            primaryLabel.textColor = newValue
            trailingLabel.textColor = newValue
        }
    }

    var alignment: NSTextAlignment = .left {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        scrollContainer.wantsLayer = true
        primaryLabel.lineBreakMode = .byClipping
        trailingLabel.lineBreakMode = .byClipping
        primaryLabel.drawsBackground = false
        trailingLabel.drawsBackground = false
        scrollContainer.addSubview(primaryLabel)
        scrollContainer.addSubview(trailingLabel)
        addSubview(scrollContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: primaryLabel.intrinsicContentSize.height)
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
        evaluateScrolling()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        stopScrolling()
    }

    override func layout() {
        super.layout()
        let textSize = primaryLabel.intrinsicContentSize
        let overflow = textSize.width > bounds.width + 1
        let originX: CGFloat
        switch alignment {
        case .center where !overflow:
            originX = (bounds.width - textSize.width) / 2
        case .right where !overflow:
            originX = bounds.width - textSize.width
        default:
            originX = 0
        }
        let originY = (bounds.height - textSize.height) / 2
        primaryLabel.frame = NSRect(origin: NSPoint(x: 0, y: originY), size: textSize)
        trailingLabel.frame = NSRect(
            origin: NSPoint(x: textSize.width + Self.gap, y: originY), size: textSize
        )
        scrollContainer.frame = NSRect(
            x: originX, y: 0, width: textSize.width * 2 + Self.gap, height: bounds.height
        )
        if !overflow {
            primaryLabel.frame.size.width = min(textSize.width, bounds.width)
        }
        evaluateScrolling()
    }

    private var overflows: Bool {
        primaryLabel.intrinsicContentSize.width - bounds.width > 1 && bounds.width > 0
    }

    private func evaluateScrolling() {
        let shouldScroll = overflows
            && isHovered
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        trailingLabel.isHidden = !shouldScroll
        guard shouldScroll else {
            stopScrolling()
            return
        }
        guard !isScrolling else { return }
        isScrolling = true
        let distance = primaryLabel.intrinsicContentSize.width + Self.gap
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -distance
        animation.duration = CFTimeInterval(distance / Self.pointsPerSecond) + 1.5
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + 0.35
        animation.fillMode = .backwards
        scrollContainer.layer?.add(animation, forKey: "marquee")
    }

    private func stopScrolling() {
        isScrolling = false
        trailingLabel.isHidden = true
        scrollContainer.layer?.removeAnimation(forKey: "marquee")
    }
}
