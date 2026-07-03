import UIKit

final class MarqueeLabel: UIView {

    private let primaryLabel = UILabel()
    private let trailingLabel = UILabel()
    private let scrollContainer = UIView()
    private var isScrolling = false

    private static let gap: CGFloat = 48
    private static let pointsPerSecond: CGFloat = 30

    var text: String? {
        didSet {
            guard text != oldValue else { return }
            primaryLabel.text = text
            trailingLabel.text = text
            accessibilityLabel = text
            restartIfNeeded()
        }
    }

    var font: UIFont {
        get { primaryLabel.font }
        set {
            primaryLabel.font = newValue
            trailingLabel.font = newValue
            invalidateIntrinsicContentSize()
            restartIfNeeded()
        }
    }

    var textColor: UIColor {
        get { primaryLabel.textColor }
        set {
            primaryLabel.textColor = newValue
            trailingLabel.textColor = newValue
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        primaryLabel.adjustsFontForContentSizeCategory = true
        trailingLabel.adjustsFontForContentSizeCategory = true
        scrollContainer.addSubview(primaryLabel)
        scrollContainer.addSubview(trailingLabel)
        addSubview(scrollContainer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartIfNeeded),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartIfNeeded),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: MarqueeLabel, _) in
            label.restartIfNeeded()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: primaryLabel.intrinsicContentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textSize = primaryLabel.intrinsicContentSize
        primaryLabel.frame = CGRect(origin: .zero, size: textSize)
        trailingLabel.frame = CGRect(
            origin: CGPoint(x: textSize.width + Self.gap, y: 0), size: textSize
        )
        scrollContainer.frame = CGRect(
            x: 0, y: 0,
            width: textSize.width * 2 + Self.gap,
            height: bounds.height
        )
        evaluateScrolling()
    }

    @objc private func restartIfNeeded() {
        isScrolling = false
        scrollContainer.layer.removeAnimation(forKey: "marquee")
        setNeedsLayout()
    }

    /// Starts the looping scroll only when the text genuinely overflows and
    /// Reduce Motion is off; otherwise the label sits static with tail truncation.
    private func evaluateScrolling() {
        let overflow = primaryLabel.intrinsicContentSize.width - bounds.width
        let shouldScroll = overflow > 1 && !UIAccessibility.isReduceMotionEnabled && bounds.width > 0
        trailingLabel.isHidden = !shouldScroll
        guard shouldScroll else {
            if isScrolling {
                isScrolling = false
                scrollContainer.layer.removeAnimation(forKey: "marquee")
            }
            scrollContainer.transform = .identity
            return
        }
        guard !isScrolling else { return }
        isScrolling = true
        let distance = primaryLabel.intrinsicContentSize.width + Self.gap
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -distance
        animation.duration = CFTimeInterval(distance / Self.pointsPerSecond) + 1.5
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + 2
        animation.fillMode = .backwards
        scrollContainer.layer.add(animation, forKey: "marquee")
    }
}
