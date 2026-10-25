import AppKit

/// The capsule that marks a song whose newest version arrived recently, in the
/// cyan the Now Playing quality badge wears so the two read as one family.
final class MacNewMixChip: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        label.stringValue = TrackVersionCopy.newMix.uppercased()
        label.font = .systemFont(ofSize: 9, weight: .heavy)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
    }

    private func applyTint() {
        let dark = effectiveAppearance.isDark
        let tint = dark
            ? NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)
            : NSColor(red: 0.0, green: 0.42, blue: 0.5, alpha: 1)
        label.textColor = tint
        layer?.borderColor = tint.withAlphaComponent(0.5).cgColor
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
    }
}

/// The small mark after a remote song's title that says the whole song is on this Mac.
final class MacDownloadedMark: NSImageView {

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: RemoteCopy.downloadedMarkLabel)
        symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = RemoteCopy.downloadedMarkLabel
        setAccessibilityElement(false)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        contentTintColor = effectiveAppearance.isDark
            ? NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)
            : NSColor(red: 0.0, green: 0.42, blue: 0.5, alpha: 1)
    }
}

/// What follows a song's title in a row: the New mix chip and then the downloaded mark. The
/// whole stack hides itself when neither shows, so a plain title keeps the room.
final class MacTitleBadges: NSStackView {

    private let chip = MacNewMixChip()
    private let mark = MacDownloadedMark()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        alignment = .centerY
        setViews([chip, mark], in: .leading)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        apply(newMix: false, downloaded: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the marks that apply; returns whether any shows.
    @discardableResult
    func apply(newMix: Bool, downloaded: Bool) -> Bool {
        chip.isHidden = !newMix
        mark.isHidden = !downloaded
        isHidden = !newMix && !downloaded
        return !isHidden
    }
}
