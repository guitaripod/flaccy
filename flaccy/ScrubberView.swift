import UIKit

/// Full-width capsule scrubber with a 44pt touch plane. Touching anywhere on
/// the track grabs the nearest position immediately, the capsule grows while
/// tracking, and selection haptics tick at the 25/50/75% detents. Playback
/// progress updates reuse the existing fill view with no per-frame allocations.
final class ScrubberView: UIControl {

    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((TimeInterval) -> Void)?
    var onScrubEnded: ((TimeInterval) -> Void)?
    var onAccessibilityAdjust: ((TimeInterval) -> Void)?

    private(set) var isScrubbing = false
    private(set) var duration: TimeInterval = 0
    private var fraction: CGFloat = 0

    private let trackView = UIView()
    private let fillView = UIView()
    private var trackHeightConstraint: NSLayoutConstraint!
    private var lastDetentZone = 0
    private let detentGenerator = UISelectionFeedbackGenerator()
    private let grabGenerator = UIImpactFeedbackGenerator(style: .light)

    private static let restingHeight: CGFloat = 7
    private static let trackingHeight: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackView.backgroundColor = .white.withAlphaComponent(0.25)
        trackView.layer.cornerCurve = .continuous
        trackView.clipsToBounds = true
        trackView.isUserInteractionEnabled = false
        trackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trackView)

        fillView.backgroundColor = .white
        fillView.isUserInteractionEnabled = false
        trackView.addSubview(fillView)

        trackHeightConstraint = trackView.heightAnchor.constraint(equalToConstant: Self.restingHeight)
        NSLayoutConstraint.activate([
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trackHeightConstraint,
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Playback position"
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.layer.cornerRadius = trackView.bounds.height / 2
        updateFillFrame()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -8).contains(point)
    }

    var currentTime: TimeInterval {
        TimeInterval(fraction) * duration
    }

    /// The x position of the playhead in this view's coordinates, for
    /// anchoring the time bubble.
    var playheadX: CGFloat {
        bounds.width * fraction
    }

    func setProgress(currentTime: TimeInterval, duration: TimeInterval) {
        self.duration = max(duration, 0)
        guard !isScrubbing else { return }
        fraction = self.duration > 0 ? CGFloat(min(max(currentTime / self.duration, 0), 1)) : 0
        updateFillFrame()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard duration > 0 else { return false }
        isScrubbing = true
        grabGenerator.impactOccurred()
        detentGenerator.prepare()
        applyFraction(fromTouch: touch)
        lastDetentZone = detentZone(for: fraction)
        setTracking(true)
        onScrubBegan?()
        onScrubChanged?(currentTime)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        applyFraction(fromTouch: touch)
        tickDetentIfCrossed()
        onScrubChanged?(currentTime)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        finishScrub()
    }

    override func cancelTracking(with event: UIEvent?) {
        finishScrub()
    }

    override func accessibilityIncrement() {
        onAccessibilityAdjust?(min(currentTime + 15, duration))
    }

    override func accessibilityDecrement() {
        onAccessibilityAdjust?(max(currentTime - 15, 0))
    }

    private func finishScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        setTracking(false)
        onScrubEnded?(currentTime)
    }

    private func applyFraction(fromTouch touch: UITouch) {
        let width = max(bounds.width, 1)
        fraction = min(max(touch.location(in: self).x / width, 0), 1)
        updateFillFrame()
    }

    private func updateFillFrame() {
        fillView.frame = CGRect(
            x: 0, y: 0, width: trackView.bounds.width * fraction, height: trackView.bounds.height
        )
    }

    private func detentZone(for fraction: CGFloat) -> Int {
        min(Int(fraction * 4), 3)
    }

    private func tickDetentIfCrossed() {
        let zone = detentZone(for: fraction)
        guard zone != lastDetentZone else { return }
        lastDetentZone = zone
        detentGenerator.selectionChanged()
        detentGenerator.prepare()
    }

    private func setTracking(_ tracking: Bool) {
        trackHeightConstraint.constant = tracking ? Self.trackingHeight : Self.restingHeight
        let update = { self.layoutIfNeeded() }
        if UIAccessibility.isReduceMotionEnabled {
            update()
        } else {
            let animator = UIViewPropertyAnimator(duration: 0.24, dampingRatio: 0.8, animations: update)
            animator.startAnimation()
        }
    }
}
