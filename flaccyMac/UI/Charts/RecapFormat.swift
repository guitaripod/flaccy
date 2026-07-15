import AppKit

/// Shared number formatting for the mac Recap surfaces: grouped counts and a
/// compact thousands/millions label. Mirrors the iOS RecapFormat exactly.
enum RecapFormat {

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

nonisolated extension NSImage {
    func pngData() -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Adaptive glass card used across the Recap dashboard and guide pages.
@MainActor
enum RecapCard {

    static func make(cornerRadius: CGFloat = 18) -> NSView {
        RecapCardView(cornerRadius: cornerRadius)
    }

    static func host(_ content: NSView, cornerRadius: CGFloat = 18) -> NSView {
        let card = make(cornerRadius: cornerRadius)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }
}

/// Layer-backed glass card that recomputes its fill and border for the active
/// appearance, honoring Reduce Transparency.
final class RecapCardView: NSView {

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacColors.fill(reduceTransparency ? 0.1 : 0.06).cgColor
            layer?.borderColor = MacColors.fill(0.08).cgColor
        }
    }
}

/// Skeleton block with a sweeping shimmer highlight; static under Reduce Motion.
final class ShimmerBlock: NSView {

    private let gradient = CAGradientLayer()

    init(cornerRadius: CGFloat = 10) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
        layer?.addSublayer(gradient)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacColors.fill(0.07).cgColor
            gradient.colors = [
                MacColors.fill(0).cgColor,
                MacColors.fill(0.09).cgColor,
                MacColors.fill(0).cgColor,
            ]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        startShimmer()
    }

    private func startShimmer() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            gradient.removeAllAnimations()
            return
        }
        guard gradient.animation(forKey: "shimmer") == nil else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.6, -0.35, -0.1]
        animation.toValue = [1.1, 1.35, 1.6]
        animation.duration = 1.35
        animation.repeatCount = .infinity
        gradient.add(animation, forKey: "shimmer")
    }
}
