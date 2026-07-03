import UIKit

final class SectionIndexView: UIView {

    var onSelectIndex: ((String) -> Void)?

    private var labels: [UILabel] = []
    private var titles: [String] = []
    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private var lastSelectedIndex: Int = -1
    private var accessibilityIndex: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Section index"
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

        subviews.forEach { $0.removeFromSuperview() }
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
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouch(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastSelectedIndex = -1
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastSelectedIndex = -1
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

        if clampedIndex != lastSelectedIndex {
            lastSelectedIndex = clampedIndex
            accessibilityIndex = clampedIndex
            accessibilityValue = titles[clampedIndex]
            feedbackGenerator.selectionChanged()
            onSelectIndex?(titles[clampedIndex])
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 16, height: UIView.noIntrinsicMetric)
    }
}
