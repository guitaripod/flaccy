import AppKit

/// A view that follows the pointer and reports hover, click and a context
/// menu, the base of every card and row on Home.
class MacHomeInteractiveView: NSView {

    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onHoverChange: ((Bool) -> Void)?

    private(set) var isHovered = false
    private(set) var isPressed = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Plain decoration inside the view answers for the view; a control or
    /// another interactive view inside it keeps its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let current = candidate, current !== self {
            if current is MacHomeInteractiveView || current is NSControl { return current }
            candidate = current.superview
        }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        stateDidChange()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        stateDidChange()
        if inside { activate() }
    }

    /// What a click does; a subclass can answer with a menu instead.
    func activate() {
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isHovered || isPressed {
            isHovered = false
            isPressed = false
            stateDidChange()
        }
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        stateDidChange()
        onHoverChange?(hovered)
    }

    /// Called whenever hover or press changes; subclasses restyle themselves.
    func stateDidChange() {}

    /// Pops `menu` just under this view, whichever way its coordinates run.
    func popUp(_ menu: NSMenu) {
        let below = isFlipped ? bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: self)
    }
}

/// A round button carrying one symbol: glass in the hero, a white disc or a
/// dark scrim over artwork. Clicking runs `onClick`, or pops its menu.
final class MacHomeCircleButton: MacHomeInteractiveView {

    enum Style {
        case glass
        case solid
        case scrim
        case plain
    }

    var menuOnClick: (() -> NSMenu?)?

    private let style: Style
    private let diameter: CGFloat
    private let icon = NSImageView()
    private let disc = NSView()
    private let highlight = NSView()

    init(symbol: String, label: String, style: Style, diameter: CGFloat = 32, pointSize: CGFloat = 13) {
        self.style = style
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true

        icon.image = MacSymbolImage.configured(symbol, pointSize: pointSize, weight: .semibold, accessibilityDescription: label)
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = tint(for: style)

        let content = NSView()
        content.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let host: NSView
        switch style {
        case .glass:
            host = MacLiquidGlass.surface(hosting: content, cornerRadius: diameter / 2)
        case .solid, .scrim:
            content.wantsLayer = true
            content.layer?.cornerRadius = diameter / 2
            content.layer?.backgroundColor = (style == .solid
                ? NSColor.white.withAlphaComponent(0.94)
                : NSColor.black.withAlphaComponent(0.5)).cgColor
            host = content
        case .plain:
            host = content
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = diameter / 2
        highlight.alphaValue = 0
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
        applyHighlightColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    private func tint(for style: Style) -> NSColor {
        switch style {
        case .solid: .black
        case .scrim: .white
        case .glass: .labelColor
        case .plain: .secondaryLabelColor
        }
    }

    override func activate() {
        if let menu = menuOnClick?() {
            popUp(menu)
        } else {
            onClick?()
        }
    }

    override func stateDidChange() {
        let target: CGFloat = isPressed ? 1 : (isHovered ? 0.6 : 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            highlight.animator().alphaValue = target
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlightColor()
    }

    private func applyHighlightColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = style == .solid ? NSColor.black.withAlphaComponent(0.1) : MacColors.fill(0.14)
            highlight.layer?.backgroundColor = color.cgColor
        }
    }
}

/// The hero's primary action: a 32 pt capsule that is light on dark and dark
/// on light, with a leading symbol.
final class MacHomeFilledButton: MacHomeInteractiveView {

    private let label: NSTextField
    private let icon = NSImageView()
    private let fill = NSView()

    init(title: String, symbol: String, height: CGFloat = 32) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = height / 2
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)

        icon.image = MacSymbolImage.configured(symbol, pointSize: 12, weight: .bold, accessibilityDescription: nil)
        icon.imageScaling = .scaleNone
        label.font = .systemFont(ofSize: 13, weight: .semibold)

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func stateDidChange() {
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.labelColor
            let alpha: CGFloat = isPressed ? 0.7 : (isHovered ? 0.88 : 1)
            fill.layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
            let ink = NSColor(name: nil) { $0.isDark ? .black : .white }
            label.textColor = ink
            icon.contentTintColor = ink
        }
    }
}

/// A text-only button, accent-coloured for "See All" and "Open Recap".
final class MacHomeLinkButton: MacHomeInteractiveView {

    private let label: NSTextField

    init(title: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold, color: NSColor = .controlAccentColor) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func stateDidChange() {
        label.alphaValue = isPressed ? 0.6 : (isHovered ? 0.8 : 1)
    }
}

/// A rounded fill with a hairline border, the surface of the Jump Back In
/// panel and the two strip cards.
class MacHomeSurfaceView: MacHomeInteractiveView {

    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        restyleSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleSurface()
    }

    private func restyleSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacColors.fill(0.06, light: 0.04).cgColor
            layer?.borderColor = MacColors.fill(0.09, light: 0.08).cgColor
        }
    }

    override func resetCursorRects() {}
}

/// The Continue card's progress: one bar per song, heard ones full, the
/// current one partly, or a single bar when the queue is too long to divide.
final class MacHomeSegmentedBar: NSView {

    static let height: CGFloat = 4
    static let gap: CGFloat = 3

    var segments: [Double] = [] {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }
        let count = CGFloat(segments.count)
        let width = (bounds.width - Self.gap * (count - 1)) / count
        guard width > 0 else { return }
        for (index, fraction) in segments.enumerated() {
            let x = CGFloat(index) * (width + Self.gap)
            let track = NSRect(x: x, y: 0, width: width, height: Self.height)
            MacColors.fill(0.2, light: 0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0 else { continue }
            let filled = NSRect(x: x, y: 0, width: max(width * clamped, Self.height), height: Self.height)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
        }
    }
}

/// The week's seven days as bars, today's in the accent colour.
final class MacHomeSparkView: NSView {

    static let size = NSSize(width: 96, height: 30)

    var daily: [Int] = [] {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { Self.size }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !daily.isEmpty else { return }
        let peak = max(daily.max() ?? 0, 1)
        let gap: CGFloat = 4
        let count = CGFloat(daily.count)
        let width = (bounds.width - gap * (count - 1)) / count
        for (index, value) in daily.enumerated() {
            let fraction = CGFloat(value) / CGFloat(peak)
            let barHeight = max(bounds.height * fraction, 3)
            let rect = NSRect(
                x: CGFloat(index) * (width + gap),
                y: bounds.height - barHeight,
                width: width,
                height: barHeight
            )
            let isToday = index == daily.count - 1
            (isToday ? NSColor.controlAccentColor : MacColors.fill(0.28, light: 0.22)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// A horizontal shelf that scrolls sideways under the pointer and hands every
/// mostly-vertical gesture to the page behind it.
final class MacHomeShelfScrollView: NSScrollView {

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// A section's heading with an optional trailing action.
final class MacHomeSectionHeader: NSView {

    init(title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        label.setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let actionTitle {
            let link = MacHomeLinkButton(title: actionTitle)
            link.onClick = action
            link.translatesAutoresizingMaskIntoConstraints = false
            addSubview(link)
            NSLayoutConstraint.activate([
                link.trailingAnchor.constraint(equalTo: trailingAnchor),
                link.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
                link.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            ])
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
