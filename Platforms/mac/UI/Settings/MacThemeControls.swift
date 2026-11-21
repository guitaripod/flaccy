import AppKit
import FlaccyCore

/// One theme in the gallery: its preview over its name, ringed in the accent
/// when it is the one worn.
final class MacThemeCard: NSControl {

    static let previewSize = NSSize(width: 156, height: 104)

    private let preview = MacThemePreviewView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let choose: () -> Void

    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isChosen)
        }
    }

    init(look: ThemeLook, isChosen: Bool, choose: @escaping () -> Void) {
        self.choose = choose
        self.isChosen = isChosen
        super.init(frame: .zero)
        preview.look = look
        preview.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = look.pack.name
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            preview.widthAnchor.constraint(equalToConstant: Self.previewSize.width),
            preview.heightAnchor.constraint(equalToConstant: Self.previewSize.height),
            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        toolTip = look.pack.description.isEmpty ? look.pack.name : look.pack.description
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(look.pack.name)
        setAccessibilityValue(isChosen)
        setAccessibilityIdentifier("themes.card.\(look.pack.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isChosen else { return }
        let radius = 9 * CGFloat(min(WornTheme.look.corners, ThemePack.cornersRound)) + 3
        let ring = NSBezierPath(
            roundedRect: preview.frame.insetBy(dx: -3.25, dy: -3.25), xRadius: radius, yRadius: radius
        )
        ring.lineWidth = 2.5
        NSColor.flaccyAccent.setStroke()
        ring.stroke()
    }
}

/// One of a theme's color schemes as a disc of its accent, ringed when it is
/// the one worn.
final class MacThemeSwatch: NSControl {

    private let color: NSColor
    private let choose: () -> Void

    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isChosen)
        }
    }

    init(name: String, color: NSColor, isChosen: Bool, choose: @escaping () -> Void) {
        self.color = color
        self.choose = choose
        self.isChosen = isChosen
        super.init(frame: .zero)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
        setAccessibilityValue(isChosen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
        NSColor.flaccySeparator.setStroke()
        let edge = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        edge.lineWidth = 0.5
        edge.stroke()
        guard isChosen else { return }
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2.25
        color.setStroke()
        ring.stroke()
    }
}
