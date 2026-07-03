import UIKit

/// A horizontally scrolling row of glass capsule chips that re-pivot the library
/// live. The selected chip fills with an active glass overlay; taps fire
/// `onSelect` with light selection haptics.
final class FilterChipsView: UIView {

    var onSelect: ((LibraryFilter) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let selection = UISelectionFeedbackGenerator()
    private var chips: [(filter: LibraryFilter, capsule: GlassCapsule)] = []
    private var selected: LibraryFilter = .all

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
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

    /// Rebuilds the chip row for the filters available in the current segment,
    /// preserving the active selection where it still applies.
    func configure(filters: [LibraryFilter], selected: LibraryFilter) {
        self.selected = selected
        chips.forEach { $0.capsule.removeFromSuperview() }
        chips.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for filter in filters {
            let capsule = makeChip(for: filter)
            stack.addArrangedSubview(capsule)
            chips.append((filter, capsule))
        }
        applySelection(animated: false)
    }

    func setSelected(_ filter: LibraryFilter, animated: Bool = true) {
        selected = filter
        applySelection(animated: animated)
    }

    private func makeChip(for filter: LibraryFilter) -> GlassCapsule {
        var config = UIButton.Configuration.plain()
        config.title = filter.displayName
        config.image = UIImage(
            systemName: filter.icon,
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
            self.setSelected(filter)
            self.onSelect?(filter)
        }, for: .touchUpInside)
        button.accessibilityLabel = "\(filter.displayName) filter"

        let capsule = GlassCapsule(hosting: button, height: 34)
        return capsule
    }

    private func applySelection(animated: Bool) {
        for chip in chips {
            let isOn = chip.filter == selected
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
            if let b = sub as? UIButton { return b }
            if let b = firstButton(in: sub) { return b }
        }
        return nil
    }
}
