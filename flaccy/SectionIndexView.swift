import UIKit

final class SectionIndexView: UIView {

    var onSelectIndex: ((String) -> Void)?

    private var labels: [UILabel] = []
    private var titles: [String] = []
    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private var lastSelectedIndex: Int = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(titles: [String]) {
        self.titles = titles
        labels.forEach { $0.removeFromSuperview() }

        labels = titles.map { title in
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 10, weight: .semibold)
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

    private func handleTouch(_ touches: Set<UITouch>) {
        guard let touch = touches.first, !titles.isEmpty else { return }
        let location = touch.location(in: self)
        let fraction = max(0, min(1, location.y / bounds.height))
        let index = Int(fraction * CGFloat(titles.count - 1))
        let clampedIndex = max(0, min(titles.count - 1, index))

        if clampedIndex != lastSelectedIndex {
            lastSelectedIndex = clampedIndex
            feedbackGenerator.selectionChanged()
            onSelectIndex?(titles[clampedIndex])
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 16, height: UIView.noIntrinsicMetric)
    }
}
