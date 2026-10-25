import AppKit

/// The outlined pill beside the title in Now Playing that spells out the song's quality. In dark
/// appearance it is the cyan outline on the backdrop; in light appearance the text is a deep teal on
/// a pale pill of its own, so its contrast holds whatever colour the backdrop takes from the cover.
final class MacQualityBadgeView: NSView {

    let label: NSTextField

    static let darkInk = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)
    static let lightInk = NSColor(red: 0.0, green: 0.29, blue: 0.35, alpha: 1)

    private static let lightFill = NSColor.white.withAlphaComponent(0.6)

    init(label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        let dark = effectiveAppearance.isDark
        let ink = dark ? Self.darkInk : Self.lightInk
        label.textColor = ink
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = ink.withAlphaComponent(dark ? 0.6 : 0.55).cgColor
            layer?.backgroundColor = dark ? NSColor.clear.cgColor : Self.lightFill.cgColor
        }
    }
}
