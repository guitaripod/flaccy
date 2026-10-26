import UIKit

/// The shape of Home while its first frame is built: the hero, the leading
/// Jump Back In tiles and a shelf of mixes, drawn as soft blocks that breathe
/// in a wave. It waits `patience` before showing, so a quick launch goes from
/// the launch screen straight to the finished page.
final class HomeLaunchPlaceholderView: UIView {

    static let patience: TimeInterval = 0.25

    private static let heroHeight: CGFloat = 268
    private static let coverSide: CGFloat = 132
    private static let tileHeight: CGFloat = 56
    private static let mixSide: CGFloat = 160
    private static let gap: CGFloat = 10
    private static let pulseKey = "home.placeholder.pulse"

    private var blocks: [UIView] = []
    private var arrangedWide: Bool?
    private var pendingAppearance: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wide = AdaptiveLayout.homeIsWide(contentWidth: bounds.width)
        guard wide != arrangedWide, bounds.width > 0 else { return }
        arrangedWide = wide
        rebuild(wide: wide)
    }

    /// Fades the blocks up once `patience` has passed, unless the page was
    /// ready first.
    func appear() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3) { self.alpha = 1 }
            self.startPulse()
        }
        pendingAppearance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: work)
    }

    /// Fades out under the arriving page and leaves the hierarchy.
    func dismiss() {
        pendingAppearance?.cancel()
        pendingAppearance = nil
        guard alpha > 0 else {
            removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    private func rebuild(wide: Bool) {
        subviews.forEach { $0.removeFromSuperview() }
        blocks = []
        let width = bounds.width
        let columnGap: CGFloat = 20
        let heroWidth = wide ? (width - columnGap) / 2 : width
        addHero(in: CGRect(x: 0, y: 0, width: heroWidth, height: Self.heroHeight))

        let tilesOrigin = wide
            ? CGPoint(x: heroWidth + columnGap, y: 0)
            : CGPoint(x: 0, y: Self.heroHeight + 22)
        let tilesWidth = wide ? heroWidth : width
        addTitle(at: tilesOrigin, width: 150)
        let tileWidth = (tilesWidth - Self.gap) / 2
        for index in 0..<4 {
            let x = tilesOrigin.x + CGFloat(index % 2) * (tileWidth + Self.gap)
            let y = tilesOrigin.y + 36 + CGFloat(index / 2) * (Self.tileHeight + Self.gap)
            addBlock(CGRect(x: x, y: y, width: tileWidth, height: Self.tileHeight), radius: 12)
        }

        let tilesBottom = tilesOrigin.y + 36 + 2 * Self.tileHeight + Self.gap
        let shelfTop = max(Self.heroHeight, tilesBottom) + 26
        addTitle(at: CGPoint(x: 0, y: shelfTop), width: 128)
        var x: CGFloat = 0
        while x < width {
            addBlock(CGRect(x: x, y: shelfTop + 36, width: Self.mixSide, height: Self.mixSide), radius: 14)
            x += Self.mixSide + 12
        }
        if alpha > 0 { startPulse() }
    }

    /// The hero's outline, with the cover, three lines of words and the play
    /// button where the real card puts them.
    private func addHero(in frame: CGRect) {
        let hero = addBlock(frame, radius: 28)
        hero.layer.borderWidth = 1
        hero.layer.borderColor = UIColor.label.withAlphaComponent(0.08).resolvedColor(with: traitCollection).cgColor
        let inset: CGFloat = 16
        let cover = CGRect(x: inset, y: inset, width: Self.coverSide, height: Self.coverSide)
        addInner(cover, radius: 12, to: hero)
        let textX = cover.maxX + 14
        let textWidth = max(frame.width - textX - inset, 0)
        for (index, fraction) in [0.45, 0.85, 0.6].enumerated() {
            let height: CGFloat = index == 1 ? 22 : 13
            let y = inset + [4, 26, 58][index]
            addInner(CGRect(x: textX, y: y, width: textWidth * fraction, height: height), radius: 5, to: hero)
        }
        let buttonY = frame.height - inset - 48
        addInner(CGRect(x: inset, y: buttonY, width: frame.width - inset * 2 - 116, height: 48), radius: 24, to: hero)
        addInner(CGRect(x: frame.width - inset - 106, y: buttonY, width: 48, height: 48), radius: 24, to: hero)
        addInner(CGRect(x: frame.width - inset - 48, y: buttonY, width: 48, height: 48), radius: 24, to: hero)
    }

    private func addTitle(at origin: CGPoint, width: CGFloat) {
        addBlock(CGRect(origin: origin, size: CGSize(width: width, height: 20)), radius: 6)
    }

    @discardableResult
    private func addBlock(_ frame: CGRect, radius: CGFloat) -> UIView {
        let block = UIView(frame: frame)
        block.backgroundColor = .tertiarySystemFill
        block.layer.cornerRadius = radius
        block.layer.cornerCurve = .continuous
        addSubview(block)
        blocks.append(block)
        return block
    }

    private func addInner(_ frame: CGRect, radius: CGFloat, to parent: UIView) {
        let inner = UIView(frame: frame)
        inner.backgroundColor = .quaternarySystemFill
        inner.layer.cornerRadius = radius
        inner.layer.cornerCurve = .continuous
        parent.addSubview(inner)
    }

    /// Each block dims and returns a beat after the one above it, so the
    /// light seems to travel down the page.
    private func startPulse() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let now = CACurrentMediaTime()
        for (index, block) in blocks.enumerated() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = now + Double(index) * 0.06
            pulse.fillMode = .backwards
            block.layer.add(pulse, forKey: Self.pulseKey)
        }
    }
}
