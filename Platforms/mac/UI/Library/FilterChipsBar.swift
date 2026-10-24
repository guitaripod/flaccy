import AppKit

/// One selectable capsule: a stable id, the words on it and its glyph. A chip
/// that carries `hasMenu` shows a chevron and offers a menu of its own.
struct FilterChip: Equatable {
    let id: String
    var title: String
    let icon: String
    var hasMenu = false

    init(id: String, title: String, icon: String, hasMenu: Bool = false) {
        self.id = id
        self.title = title
        self.icon = icon
        self.hasMenu = hasMenu
    }

    init(filter: LibraryFilter) {
        self.init(id: filter.rawValue, title: filter.displayName, icon: filter.icon)
    }
}

/// Horizontal row of quick-pivot filter chips mirroring the iOS
/// FilterChipsView: one selected capsule, hover brightening, adaptive colors
/// that hold up in both appearances.
final class FilterChipsBar: NSView {

    var onSelect: ((LibraryFilter) -> Void)?
    var onSelectChip: ((String) -> Void)?
    var menuProvider: ((String) -> NSMenu?)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var buttons: [ChipButton] = []

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
        configure(chips: filters.map(FilterChip.init(filter:)), selected: selected.rawValue)
    }

    func configure(chips: [FilterChip], selected: String) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = chips.map { chip in
            let button = ChipButton(chip: chip)
            button.isChosen = chip.id == selected
            button.onClick = { [weak self] in self?.choose(chip.id) }
            button.menuProvider = { [weak self] in self?.menuProvider?(chip.id) }
            return button
        }
        buttons.forEach { stack.addArrangedSubview($0) }
    }

    /// Rewords chips in place, so a chip whose title carries a setting
    /// ("Most Played · 7D") can change without the bar being rebuilt.
    func update(chips: [FilterChip]) {
        for chip in chips {
            buttons.first { $0.chip.id == chip.id }?.apply(chip)
        }
    }

    func setSelected(_ filter: LibraryFilter) {
        setSelected(id: filter.rawValue)
    }

    func setSelected(id: String) {
        for button in buttons {
            button.isChosen = button.chip.id == id
        }
    }

    private func choose(_ id: String) {
        setSelected(id: id)
        onSelectChip?(id)
        if let filter = LibraryFilter(rawValue: id) {
            onSelect?(filter)
        }
    }
}

private final class ChipButton: NSControl {

    private(set) var chip: FilterChip
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    var isChosen = false {
        didSet { applyColors() }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isHovered = false

    private static let chevronHitWidth: CGFloat = 26

    init(chip: FilterChip) {
        self.chip = chip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous

        iconView.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 8, weight: .bold)

        let stack = NSStackView(views: [iconView, label, chevron])
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
        apply(chip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ chip: FilterChip) {
        self.chip = chip
        iconView.image = NSImage(systemSymbolName: chip.icon, accessibilityDescription: nil)
        label.stringValue = chip.title
        chevron.isHidden = !chip.hasMenu
        setAccessibilityLabel(String(localized: "Filter: \(chip.title)"))
        applyColors()
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
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if chip.hasMenu, point.x > bounds.width - Self.chevronHitWidth, let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        chip.hasMenu ? menuProvider?() : nil
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
                chevron.contentTintColor = .windowBackgroundColor
            } else {
                let base = NSColor.labelColor.withAlphaComponent(isHovered ? 0.16 : 0.09)
                layer?.backgroundColor = base.cgColor
                label.textColor = .labelColor
                iconView.contentTintColor = .secondaryLabelColor
                chevron.contentTintColor = .secondaryLabelColor
            }
        }
    }
}
