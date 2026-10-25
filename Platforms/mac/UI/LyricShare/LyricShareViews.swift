import AppKit

/// The window's root view: it takes first responder so Space and Escape reach
/// the view controller when no control has the keyboard.
final class LyricShareRootView: NSView {

    override var acceptsFirstResponder: Bool { true }
}

/// The dark well the preview sits in. It keeps the preview image at the
/// format's aspect, as large as fits, with the play button over the image's
/// bottom-right corner.
final class LyricSharePreviewWell: NSView {

    let imageView = NSImageView()
    let playButton = NSButton()
    let spinner = NSProgressIndicator()
    var onPreviewResize: (() -> Void)?
    var aspect: CGFloat = 9.0 / 16.0 {
        didSet {
            if aspect != oldValue { needsLayout = true }
        }
    }

    private static let padding: CGFloat = 20
    private static let cornerRadius: CGFloat = 14
    private static let buttonSide: CGFloat = 36
    private static let buttonInset: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel(LyricShareCopy.sheetTitle)
        addSubview(imageView)

        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.setButtonType(.momentaryChange)
        playButton.contentTintColor = .white
        playButton.wantsLayer = true
        playButton.layer?.cornerRadius = Self.buttonSide / 2
        playButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        addSubview(playButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        guard available.width > 1, available.height > 1 else { return }
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        let frame = NSRect(
            x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height
        ).integral
        let resized = imageView.frame.size != frame.size
        imageView.frame = frame
        let button = NSRect(
            x: frame.maxX - Self.buttonInset - Self.buttonSide, y: frame.minY + Self.buttonInset,
            width: Self.buttonSide, height: Self.buttonSide)
        playButton.frame = button
        spinner.frame = button.insetBy(dx: 8, dy: 8)
        if resized { onPreviewResize?() }
    }
}

/// A flat, rounded choice button: a symbol over its name, filled with the
/// accent colour at low alpha while chosen. The templates, colours and the
/// plain toggles share it.
final class LyricShareChipButton: NSButton {

    var isChosen = false {
        didSet { applyColors() }
    }
    var showsChosenBackground = true {
        didSet { applyColors() }
    }
    private var caption = ""

    override var isHighlighted: Bool {
        didSet { alphaValue = isHighlighted ? 0.65 : 1 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageAbove
        imageHugsTitle = true
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(title: String, symbol: String?, hint: String? = nil) {
        caption = title
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        toolTip = hint ?? title
        setAccessibilityLabel(title)
        if let hint { setAccessibilityHelp(hint) }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Repaints the chip for its current state. The layer's colours are
    /// resolved against the view's own appearance so a switch between light
    /// and dark mode repaints them.
    private func applyColors() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let ink: NSColor = isChosen ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: caption,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ])
        contentTintColor = isChosen ? .controlAccentColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let filled = isChosen && showsChosenBackground
            layer?.backgroundColor = (filled
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.labelColor.withAlphaComponent(showsChosenBackground ? 0.06 : 0)).cgColor
            layer?.borderColor = (filled ? NSColor.controlAccentColor : NSColor.clear).cgColor
        }
    }
}

/// One line in the picker: its words, a checkmark and an accent wash while it
/// is part of the clip. An interlude, or any row while a video is being made,
/// does not respond.
final class LyricShareLineRow: NSView {

    var onClick: (() -> Void)?
    var isLocked = false {
        didSet { applyState() }
    }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let isPickable: Bool
    private var isChosen = false

    init(text: String, pickable: Bool) {
        isPickable = pickable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        label.stringValue = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = .controlAccentColor
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(check)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(pickable ? .checkBox : .staticText)
        setAccessibilityLabel(text)
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setChosen(_ chosen: Bool) {
        guard chosen != isChosen else { return }
        isChosen = chosen
        applyState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isPickable, !isLocked else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isPickable, !isLocked else { return false }
        onClick?()
        return true
    }

    override func resetCursorRects() {
        if isPickable && !isLocked { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyState()
    }

    private func applyState() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isChosen
                ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.clear).cgColor
        }
        label.textColor = isChosen ? .labelColor : (isPickable ? .secondaryLabelColor : .tertiaryLabelColor)
        check.isHidden = !isChosen
        alphaValue = isLocked ? 0.5 : 1
        setAccessibilityValue(isChosen)
        window?.invalidateCursorRects(for: self)
    }
}
