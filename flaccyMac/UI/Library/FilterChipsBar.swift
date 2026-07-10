import AppKit

/// Horizontal row of quick-pivot filter chips mirroring the iOS
/// FilterChipsView: one selected capsule, hover brightening, adaptive colors
/// that hold up in both appearances.
final class FilterChipsBar: NSView {

    var onSelect: ((LibraryFilter) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var buttons: [ChipButton] = []
    private var selected: LibraryFilter = .all

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let clipDocument = FlippedView()
        clipDocument.translatesAutoresizingMaskIntoConstraints = false
        clipDocument.addSubview(stack)

        scrollView.documentView = clipDocument
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: clipDocument.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipDocument.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: clipDocument.bottomAnchor),
            clipDocument.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            clipDocument.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(filters: [LibraryFilter], selected: LibraryFilter) {
        self.selected = selected
        buttons.forEach { $0.removeFromSuperview() }
        buttons = filters.map { filter in
            let button = ChipButton(filter: filter)
            button.isChosen = filter == selected
            button.onClick = { [weak self] in self?.choose(filter) }
            return button
        }
        buttons.forEach { stack.addArrangedSubview($0) }
    }

    func setSelected(_ filter: LibraryFilter) {
        selected = filter
        for button in buttons {
            button.isChosen = button.filter == filter
        }
    }

    private func choose(_ filter: LibraryFilter) {
        setSelected(filter)
        onSelect?(filter)
    }
}

private final class ChipButton: NSControl {

    let filter: LibraryFilter
    var onClick: (() -> Void)?

    var isChosen = false {
        didSet { applyColors() }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false

    init(filter: LibraryFilter) {
        self.filter = filter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous

        iconView.image = NSImage(systemSymbolName: filter.icon, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 10, weight: .semibold)

        label.stringValue = filter.displayName
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel("Filter: \(filter.displayName)")
        applyColors()
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
        isHovered = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            if isChosen {
                layer?.backgroundColor = NSColor.labelColor.cgColor
                label.textColor = .windowBackgroundColor
                iconView.contentTintColor = .windowBackgroundColor
            } else {
                let base = NSColor.labelColor.withAlphaComponent(isHovered ? 0.16 : 0.09)
                layer?.backgroundColor = base.cgColor
                label.textColor = .labelColor
                iconView.contentTintColor = .secondaryLabelColor
            }
        }
    }
}
