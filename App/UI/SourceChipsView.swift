import UIKit

/// The second row of chips under the filter chips: this device and each server. At most one is
/// lit, and tapping the lit one turns it off so every source shows again.
final class SourceChipsView: UIView {

    var onSelect: ((LibrarySource?) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let selection = UISelectionFeedbackGenerator()
    private var chips: [(choice: LibrarySourceChoice, capsule: GlassCapsule)] = []
    private var selected: LibrarySource?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        scrollView.clipsToBounds = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(choices: [LibrarySourceChoice], selected: LibrarySource?) {
        self.selected = selected
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips = choices.map { choice in
            let capsule = makeChip(for: choice)
            stack.addArrangedSubview(capsule)
            return (choice, capsule)
        }
        applySelection(animated: false)
    }

    func setSelected(_ source: LibrarySource?, animated: Bool = true) {
        selected = source
        applySelection(animated: animated)
    }

    private func makeChip(for choice: LibrarySourceChoice) -> GlassCapsule {
        var config = UIButton.Configuration.plain()
        config.title = choice.title
        config.image = UIImage(
            systemName: choice.icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        config.imagePadding = 5
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.subheadline, size: 13, weight: .semibold)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.selection.selectionChanged()
            let next: LibrarySource? = self.selected == choice.source ? nil : choice.source
            self.setSelected(next)
            self.onSelect?(next)
        }, for: .touchUpInside)
        button.accessibilityLabel = String(localized: "\(choice.title) source")
        return GlassCapsule(hosting: button, height: 34)
    }

    private func applySelection(animated: Bool) {
        for chip in chips {
            let isOn = chip.choice.source == selected
            chip.capsule.setActive(isOn, animated: animated)
            chip.capsule.accessibilityTraits = isOn ? [.button, .selected] : .button
            if let button = firstButton(in: chip.capsule) {
                button.isSelected = isOn
                button.accessibilityTraits = isOn ? [.button, .selected] : .button
            }
        }
    }

    private func firstButton(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let button = sub as? UIButton { return button }
            if let button = firstButton(in: sub) { return button }
        }
        return nil
    }
}
