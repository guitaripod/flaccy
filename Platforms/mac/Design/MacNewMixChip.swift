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
