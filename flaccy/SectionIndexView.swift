import UIKit

final class SectionIndexView: UIView {

    var onSelectIndex: ((String) -> Void)?

    private var labels: [UILabel] = []
    private var titles: [String] = []
    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private var lastSelectedIndex: Int = -1
    private var accessibilityIndex: Int = 0
    private let pillBackground = LiquidGlass.view(cornerRadius: 8)
    private let bubbleView = UIView()
    private let bubbleLabel = UILabel()
    private var bubbleGlass: UIVisualEffectView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Section index"
        setupPill()
        setupBubble()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String]) {
        self.titles = titles
        labels.forEach { $0.removeFromSuperview() }

        labels = titles.map { title in
            let label = UILabel()
            label.text = title
            label.font = .scaled(.caption2, size: 10, weight: .semibold, maxSize: 13)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .tintColor
            label.textAlignment = .center
            return label
        }

        let stack = UIStackView(arrangedSubviews: labels)
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        subviews.filter { $0 !== pillBackground }.forEach { $0.removeFromSuperview() }
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        isHidden = titles.isEmpty
        accessibilityIndex = 0
        accessibilityValue = titles.first
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedbackGenerator.prepare()
        handleTouch(touches)
        setBubbleVisible(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouch(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastSelectedIndex = -1
        setBubbleVisible(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastSelectedIndex = -1
        setBubbleVisible(false)
    }

    override func accessibilityIncrement() {
        selectForAccessibility(index: accessibilityIndex + 1)
    }

    override func accessibilityDecrement() {
        selectForAccessibility(index: accessibilityIndex - 1)
    }

    private func selectForAccessibility(index: Int) {
        guard !titles.isEmpty else { return }
        let clamped = max(0, min(titles.count - 1, index))
        guard clamped != accessibilityIndex else { return }
        accessibilityIndex = clamped
        let title = titles[clamped]
        accessibilityValue = title
        onSelectIndex?(title)
        UIAccessibility.post(notification: .announcement, argument: title)
    }

    private func handleTouch(_ touches: Set<UITouch>) {
        guard let touch = touches.first, !titles.isEmpty else { return }
        let location = touch.location(in: self)
        let fraction = max(0, min(1, location.y / bounds.height))
        let index = Int(fraction * CGFloat(titles.count))
        let clampedIndex = max(0, min(titles.count - 1, index))
        positionBubble(atFractionalY: location.y)

        if clampedIndex != lastSelectedIndex {
            lastSelectedIndex = clampedIndex
            accessibilityIndex = clampedIndex
            accessibilityValue = titles[clampedIndex]
            bubbleLabel.text = titles[clampedIndex]
            feedbackGenerator.selectionChanged()
            onSelectIndex?(titles[clampedIndex])
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 16, height: UIView.noIntrinsicMetric)
    }

    private func setupPill() {
        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.isUserInteractionEnabled = false
        addSubview(pillBackground)
        NSLayoutConstraint.activate([
            pillBackground.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            pillBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 4),
            pillBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Builds the floating letter HUD shown beside the index while scrubbing,
    /// glass-backed with a solid fallback under Reduce Transparency.
    private func setupBubble() {
        bubbleView.alpha = 0
        bubbleView.isUserInteractionEnabled = false
        if UIAccessibility.isReduceTransparencyEnabled {
            bubbleView.backgroundColor = .secondarySystemBackground
        } else {
            let glass = LiquidGlass.view(cornerRadius: 26)
            glass.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
            glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            bubbleView.addSubview(glass)
            bubbleGlass = glass
        }
        bubbleView.layer.cornerRadius = 26
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.layer.shadowColor = UIColor.black.cgColor
        bubbleView.layer.shadowOpacity = 0.2
        bubbleView.layer.shadowOffset = CGSize(width: 0, height: 4)
        bubbleView.layer.shadowRadius = 10

        bubbleLabel.font = .scaled(.title2, size: 24, weight: .bold, maxSize: 30)
        bubbleLabel.adjustsFontForContentSizeCategory = true
        bubbleLabel.textColor = .label
        bubbleLabel.textAlignment = .center
        bubbleLabel.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
        bubbleLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        (bubbleGlass?.contentView ?? bubbleView).addSubview(bubbleLabel)
        bubbleView.bounds = CGRect(x: 0, y: 0, width: 52, height: 52)
    }

    private func positionBubble(atFractionalY y: CGFloat) {
        guard let superview else { return }
        if bubbleView.superview !== superview {
            superview.addSubview(bubbleView)
        }
        let clampedY = max(26, min(bounds.height - 26, y))
        let center = superview.convert(CGPoint(x: -46, y: clampedY), from: self)
        bubbleView.center = center
    }

    private func setBubbleVisible(_ visible: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            bubbleView.alpha = visible ? 1 : 0
            bubbleView.transform = .identity
            return
        }
        if visible {
            bubbleView.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.7) {
                self.bubbleView.alpha = 1
                self.bubbleView.transform = .identity
            }
            animator.startAnimation()
        } else {
            let animator = UIViewPropertyAnimator(duration: 0.2, dampingRatio: 1) {
                self.bubbleView.alpha = 0
                self.bubbleView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
            animator.startAnimation()
        }
    }
}
