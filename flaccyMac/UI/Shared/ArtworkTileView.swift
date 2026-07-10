import AppKit

/// Rounded artwork surface shared by every library and detail screen: a
/// deterministic FNV-1a placeholder gradient with an animated shimmer sweep
/// while the real artwork decodes, then the image scaled to fill.
final class ArtworkTileView: NSView {

    private let gradientLayer = CAGradientLayer()
    private let shimmerLayer = CAGradientLayer()
    private let imageLayer = CALayer()

    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradientLayer)

        shimmerLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.16).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.isHidden = true
        layer?.addSublayer(shimmerLayer)

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        shimmerLayer.frame = bounds
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func showPlaceholder(seed: String, shimmering: Bool) {
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [base.cgColor, second.cgColor]
        imageLayer.contents = nil
        imageLayer.isHidden = true
        CATransaction.commit()
        setShimmering(shimmering)
    }

    func showImage(_ image: NSImage) {
        setShimmering(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.isHidden = false
        CATransaction.commit()
    }

    func stopShimmer() {
        setShimmering(false)
    }

    private func setShimmering(_ shimmering: Bool) {
        let animate = shimmering && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shimmerLayer.isHidden = !animate
        if animate {
            guard shimmerLayer.animation(forKey: "shimmer") == nil else { return }
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-1.0, -0.5, 0.0]
            sweep.toValue = [1.0, 1.5, 2.0]
            sweep.duration = 1.35
            sweep.repeatCount = .infinity
            shimmerLayer.add(sweep, forKey: "shimmer")
        } else {
            shimmerLayer.removeAnimation(forKey: "shimmer")
        }
    }
}
