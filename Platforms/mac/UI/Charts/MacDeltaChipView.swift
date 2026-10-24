import AppKit

/// The small pill beside a stat tile's value saying how the period compared
/// with the one just before it: an arrow and a percentage, "New", or "Even".
final class MacDeltaChipView: NSView {

    private let label = NSTextField(labelWithString: "")

    /// Nil for `.none`: a metric with nothing on either side has no chip.
    init?(delta: PeriodDelta, accent: NSColor) {
        guard let text = Self.text(for: delta) else { return nil }
        super.init(frame: .zero)
        let color = Self.color(for: delta, accent: accent)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = color.withAlphaComponent(0.22).cgColor

        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.textColor = color.blended(withFraction: 0.55, of: .white) ?? color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func text(for delta: PeriodDelta) -> String? {
        switch delta {
        case .none: nil
        case .up(let percent): "\u{25B2} \(percent)%"
        case .down(let percent): "\u{25BC} \(percent)%"
        case .new: String(localized: "New")
        case .even: String(localized: "Even")
        }
    }

    private static func color(for delta: PeriodDelta, accent: NSColor) -> NSColor {
        switch delta {
        case .up, .new: accent
        case .down: NSColor(red: 0.96, green: 0.50, blue: 0.38, alpha: 1)
        case .even, .none: MacColors.secondaryLabel
        }
    }
}
