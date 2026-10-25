import UIKit

/// The Continue card's progress: one bar segment per track, filled up to
/// where the person stopped, or one continuous bar for a long queue.
final class HomeSegmentedProgressView: UIView {

    static let height: CGFloat = 4
    private static let gap: CGFloat = 3

    private var segments: [Double] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HomeSegmentedProgressView, _) in view.setNeedsDisplay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func setSegments(_ values: [Double]) {
        guard values != segments else { return }
        segments = values
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !segments.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let count = CGFloat(segments.count)
        let width = (bounds.width - Self.gap * (count - 1)) / count
        let track = UIColor.label.withAlphaComponent(0.18).resolvedColor(with: traitCollection)
        let fill = UIColor.label.resolvedColor(with: traitCollection)
        for (index, fraction) in segments.enumerated() {
            let frame = CGRect(x: CGFloat(index) * (width + Self.gap), y: 0, width: width, height: bounds.height)
            let radius = bounds.height / 2
            context.setFillColor(track.cgColor)
            context.addPath(UIBezierPath(roundedRect: frame, cornerRadius: radius).cgPath)
            context.fillPath()
            guard fraction > 0 else { continue }
            let filled = CGRect(x: frame.minX, y: 0, width: max(frame.width * CGFloat(min(fraction, 1)), bounds.height), height: bounds.height)
            context.setFillColor(fill.cgColor)
            context.addPath(UIBezierPath(roundedRect: filled, cornerRadius: radius).cgPath)
            context.fillPath()
        }
    }
}
