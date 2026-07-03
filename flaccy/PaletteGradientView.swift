import UIKit

/// A static, dark ambient backdrop tinted by an ArtworkPalette: palette colors
/// are blended toward black and laid out as a diagonal gradient with a scrim so
/// foreground content keeps contrast on any artwork.
final class PaletteGradientView: UIView {

    private let gradientLayer = CAGradientLayer()
    private let scrimLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        gradientLayer.startPoint = CGPoint(x: 0.1, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.9, y: 1)
        layer.addSublayer(gradientLayer)
        scrimLayer.colors = [
            UIColor.black.withAlphaComponent(0.5).cgColor,
            UIColor.black.withAlphaComponent(0.25).cgColor,
            UIColor.black.withAlphaComponent(0.6).cgColor,
        ]
        scrimLayer.locations = [0, 0.4, 1]
        layer.addSublayer(scrimLayer)
        apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"), animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        scrimLayer.frame = bounds
        CATransaction.commit()
    }

    func apply(_ palette: ArtworkPalette, animated: Bool) {
        let source = palette.colors.isEmpty ? [UIColor.systemIndigo] : palette.colors
        var stops = [
            darkened(source[0], by: 0.45),
            darkened(source[min(1, source.count - 1)], by: 0.62),
            darkened(source[min(2, source.count - 1)], by: 0.78),
        ]
        stops.append(UIColor.black)
        let cgColors = stops.map(\.cgColor)
        if animated {
            let transition = CABasicAnimation(keyPath: "colors")
            transition.fromValue = gradientLayer.presentation()?.colors ?? gradientLayer.colors
            transition.toValue = cgColors
            transition.duration = 0.6
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradientLayer.add(transition, forKey: "colors")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = cgColors
        CATransaction.commit()
    }

    private func darkened(_ color: UIColor, by fraction: CGFloat) -> UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let keep = 1 - fraction
        return UIColor(red: r * keep, green: g * keep, blue: b * keep, alpha: 1)
    }
}
