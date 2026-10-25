import UIKit

/// Seven small bars, one per day, with today's in the label colour.
final class HomeSparkView: UIView {

    static let height: CGFloat = 56
    private static let gap: CGFloat = 4
    private static let minimumBar: CGFloat = 4
    private static let maximumBarWidth: CGFloat = 24

    private var values: [Int] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HomeSparkView, _) in view.setNeedsDisplay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func setValues(_ daily: [Int]) {
        guard daily != values else { return }
        values = daily
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !values.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let peak = CGFloat(max(values.max() ?? 1, 1))
        let count = CGFloat(values.count)
        let width = min((bounds.width - Self.gap * (count - 1)) / count, Self.maximumBarWidth)
        let others = UIColor.label.withAlphaComponent(0.24).resolvedColor(with: traitCollection)
        let today = UIColor.label.resolvedColor(with: traitCollection)
        for (index, value) in values.enumerated() {
            let height = max(bounds.height * CGFloat(value) / peak, Self.minimumBar)
            let bar = CGRect(
                x: CGFloat(index) * (width + Self.gap), y: bounds.height - height, width: width, height: height
            )
            context.setFillColor((index == values.count - 1 ? today : others).cgColor)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: min(width, height) / 3).cgPath)
            context.fillPath()
        }
    }
}
