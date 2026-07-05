import UIKit

/// Capsule scrubber built on a real UISlider so touch tracking is fully
/// native — vertical finger drift never cancels a scrub and the sheet's
/// dismiss pan defers to it. Touching anywhere on the track grabs that
/// position, the capsule grows while tracking, and selection haptics tick
/// at the quarter detents.
final class ScrubberView: UISlider {

    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((TimeInterval) -> Void)?
    var onScrubEnded: ((TimeInterval) -> Void)?
    var onAccessibilityAdjust: ((TimeInterval) -> Void)?

    private(set) var isScrubbing = false
    private(set) var duration: TimeInterval = 0
    private var isAbortingScrub = false
    private var lastDetentZone = 0
    private let detentGenerator = UISelectionFeedbackGenerator()
    private let grabGenerator = UIImpactFeedbackGenerator(style: .light)

    private static let restingHeight: CGFloat = 7
    private static let trackingHeight: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumValue = 0
        maximumValue = 1
        minimumTrackTintColor = .white
        maximumTrackTintColor = .white.withAlphaComponent(0.25)
        setThumbImage(UIImage(), for: .normal)
        setThumbImage(UIImage(), for: .highlighted)
        addTarget(self, action: #selector(valueDidChange), for: .valueChanged)
        accessibilityLabel = "Playback position"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let height = isScrubbing ? Self.trackingHeight : Self.restingHeight
        return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -8).contains(point)
    }

    var currentTime: TimeInterval {
        TimeInterval(value) * duration
    }

    var playheadX: CGFloat {
        bounds.width * CGFloat(value)
    }

    func setProgress(currentTime: TimeInterval, duration: TimeInterval) {
        self.duration = max(duration, 0)
        guard !isScrubbing else { return }
        value = self.duration > 0 ? Float(min(max(currentTime / self.duration, 0), 1)) : 0
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard duration > 0 else { return false }
        if isScrubbing {
            AppLogger.warning("scrub beginTracking while already scrubbing — recovering stale scrub", category: .ui)
            finishScrub()
        }
        isScrubbing = true
        AppLogger.debug("scrub beginTracking", category: .ui)
        grabGenerator.impactOccurred()
        detentGenerator.prepare()
        value = grabbedValue(for: touch)
        lastDetentZone = detentZone(for: value)
        animateTrackHeight()
        onScrubBegan?()
        onScrubChanged?(currentTime)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        value = grabbedValue(for: touch)
        tickDetentIfCrossed()
        onScrubChanged?(currentTime)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        AppLogger.debug("scrub endTracking", category: .ui)
        finishScrub()
    }

    override func cancelTracking(with event: UIEvent?) {
        AppLogger.debug("scrub cancelTracking", category: .ui)
        finishScrub()
    }

    /// UIControl's endTracking is not guaranteed to arrive — an ancestor
    /// gesture recognizer can swallow the touch-up — so the raw touch events
    /// are a second line of defense that ends the scrub no matter what the
    /// control-tracking machinery saw.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if isScrubbing {
            AppLogger.warning("scrub finished via touchesEnded fallback", category: .ui)
            finishScrub()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if isScrubbing {
            AppLogger.warning("scrub finished via touchesCancelled fallback", category: .ui)
            finishScrub()
        }
    }

    override func accessibilityIncrement() {
        onAccessibilityAdjust?(min(currentTime + 15, duration))
    }

    override func accessibilityDecrement() {
        onAccessibilityAdjust?(max(currentTime - 15, 0))
    }

    @objc private func valueDidChange() {
        AppLogger.debug("scrub valueChanged native value=\(value) isScrubbing=\(isScrubbing)", category: .ui)
        guard isScrubbing else { return }
        onScrubChanged?(currentTime)
    }

    private func grabbedValue(for touch: UITouch) -> Float {
        let width = max(bounds.width, 1)
        return Float(min(max(touch.location(in: self).x / width, 0), 1))
    }

    /// Ends an in-flight scrub without emitting `onScrubEnded`, for when the
    /// track changes underneath the gesture and seeking to the grabbed
    /// position would land on the wrong song.
    func abortScrub() {
        guard isScrubbing else { return }
        AppLogger.debug("scrub aborted (track changed)", category: .ui)
        isAbortingScrub = true
        cancelTracking(with: nil)
        isAbortingScrub = false
    }

    private func finishScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        animateTrackHeight()
        guard !isAbortingScrub else { return }
        onScrubEnded?(currentTime)
    }

    private func animateTrackHeight() {
        let update = { self.setNeedsLayout(); self.layoutIfNeeded() }
        if UIAccessibility.isReduceMotionEnabled {
            update()
        } else {
            UIViewPropertyAnimator(duration: 0.24, dampingRatio: 0.8, animations: update).startAnimation()
        }
    }

    private func detentZone(for value: Float) -> Int {
        min(Int(value * 4), 3)
    }

    private func tickDetentIfCrossed() {
        let zone = detentZone(for: value)
        guard zone != lastDetentZone else { return }
        lastDetentZone = zone
        detentGenerator.selectionChanged()
        detentGenerator.prepare()
    }
}
