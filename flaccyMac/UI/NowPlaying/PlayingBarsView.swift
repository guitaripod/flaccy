import AppKit

/// Three bouncing equalizer bars marking the playing row. Bars animate only
/// while playback runs and Reduce Motion is off; otherwise they freeze at a
/// low static height.
final class PlayingBarsView: NSView {

    private let barLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var animating = false

    var tint: NSColor = .white {
        didSet { barLayers.forEach { $0.backgroundColor = tint.cgColor } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in barLayers {
            bar.backgroundColor = tint.cgColor
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 14) }

    override func layout() {
        super.layout()
        let barWidth: CGFloat = 3
        let gap = (bounds.width - barWidth * 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            bar.frame = CGRect(
                x: CGFloat(index) * (barWidth + gap), y: 0, width: barWidth, height: staticHeight(index)
            )
        }
        CATransaction.commit()
        if animating { restartAnimations() }
    }

    func setPlaying(_ playing: Bool) {
        let shouldAnimate = playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate != animating else { return }
        animating = shouldAnimate
        if shouldAnimate {
            restartAnimations()
        } else {
            barLayers.forEach { $0.removeAllAnimations() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if animating { restartAnimations() }
    }

    private func staticHeight(_ index: Int) -> CGFloat {
        [5, 8, 4][index]
    }

    private func restartAnimations() {
        for (index, bar) in barLayers.enumerated() {
            bar.removeAllAnimations()
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = 3 + CGFloat(index)
            animation.toValue = bounds.height - CGFloat(index) * 2
            animation.duration = 0.5 + Double(index) * 0.13
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "bounce")
            var frame = bar.frame
            frame.origin.y = 0
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.position = CGPoint(x: frame.midX, y: 0)
        }
    }
}
