import FlaccyCore
import UIKit

/// Three vertical bars that bounce while the track is playing and freeze at
/// staggered heights when paused; Reduce Motion keeps them static.
/// Three animated bars that stand in for the track number on the row the
/// player is on. Shared by album detail and playlist detail.
final class NowPlayingBarsView: UIView {

    let barLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for bar in barLayers {
            bar.cornerRadius = 1.25
            layer.addSublayer(bar)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartIfNeeded),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for bar in barLayers {
            bar.backgroundColor = tintColor.cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barWidth: CGFloat = 2.5
        let spacing = (bounds.width - barWidth * 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let x = CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: 0, width: barWidth, height: bounds.height)
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.position = CGPoint(x: x + barWidth / 2, y: bounds.height)
            bar.backgroundColor = tintColor.cgColor
        }
        CATransaction.commit()
        applyBarState()
    }

    func setAnimating(_ animating: Bool) {
        isAnimating = animating
        applyBarState()
    }

    @objc func restartIfNeeded() {
        applyBarState()
    }

    func applyBarState() {
        let restScales: [CGFloat] = [0.45, 0.8, 0.6]
        guard isAnimating, !UIAccessibility.isReduceMotionEnabled, window != nil || superview != nil else {
            for (index, bar) in barLayers.enumerated() {
                bar.removeAnimation(forKey: "bounce")
                bar.transform = CATransform3DMakeScale(1, restScales[index], 1)
            }
            return
        }
        for (index, bar) in barLayers.enumerated() {
            guard bar.animation(forKey: "bounce") == nil else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = restScales[index]
            animation.toValue = 1.0
            animation.duration = 0.36 + Double(index) * 0.08
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "bounce")
        }
    }
}
