import UIKit

/// A horizontally scrolling row of glass capsule chips that re-pivot the library
/// live. The selected chip fills with an active glass overlay and takes the
/// accent; any chip but All also shows a cross, and tapping it again goes back
/// to All, so the way out is always the chip in view. Taps fire `onSelect` with
/// selection haptics.
final class FilterChipsView: UIView {

    var onSelect: ((LibraryFilter) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let selection = UISelectionFeedbackGenerator()
    private var chips: [(filter: LibraryFilter, capsule: GlassCapsule, button: UIButton)] = []
    private var selected: LibraryFilter = .all
    private var needsReveal = false

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

    override func layoutSubviews() {
        super.layoutSubviews()
        guard needsReveal, bounds.width > 0 else { return }
        needsReveal = false
        revealSelectedChip(animated: false)
    }

    /// Rebuilds the chip row for the filters available in the current segment,
    /// preserving the active selection where it still applies.
    func configure(filters: [LibraryFilter], selected: LibraryFilter) {
        self.selected = selected
        chips.forEach { $0.capsule.removeFromSuperview() }
        chips.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for filter in filters {
            let (capsule, button) = makeChip(for: filter)
            stack.addArrangedSubview(capsule)
            chips.append((filter, capsule, button))
        }
        applySelection(animated: false)
        needsReveal = true
        setNeedsLayout()
    }

    /// Lights `filter`, and brings it into view when the selection moved; the
    /// same selection repeated by a snapshot leaves the row where the reader
    /// scrolled it.
    func setSelected(_ filter: LibraryFilter, animated: Bool = true) {
        guard filter != selected else { return }
        selected = filter
        applySelection(animated: animated)
        layoutIfNeeded()
        revealSelectedChip(animated: animated)
    }

    private func makeChip(for filter: LibraryFilter) -> (GlassCapsule, UIButton) {
        var config = UIButton.Configuration.plain()
        config.title = filter.displayName
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.subheadline, size: 13, weight: .semibold)
            return outgoing
        }

        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let next = self.selected == filter ? LibraryFilter.all : filter
            guard next != self.selected else { return }
            self.selection.selectionChanged()
            self.setSelected(next)
            self.onSelect?(next)
        }, for: .touchUpInside)
        button.accessibilityLabel = String(localized: "\(filter.displayName) filter")

        let capsule = GlassCapsule(hosting: button, height: 34)
        return (capsule, button)
    }

    private func applySelection(animated: Bool) {
        for chip in chips {
            let isOn = chip.filter == selected
            chip.capsule.setActive(isOn, animated: animated)
            chip.capsule.accessibilityTraits = isOn ? [.button, .selected] : .button
            style(chip.button, for: chip.filter, isOn: isOn)
        }
    }

    /// A lit chip other than All trades its icon for a trailing cross, the cue
    /// that tapping it again shows everything.
    private func style(_ button: UIButton, for filter: LibraryFilter, isOn: Bool) {
        let clears = isOn && filter != .all
        guard var config = button.configuration else { return }
        config.image = UIImage(
            systemName: clears ? "xmark" : filter.icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: clears ? 10 : 11, weight: clears ? .bold : .semibold)
        )
        config.imagePlacement = clears ? .trailing : .leading
        config.baseForegroundColor = isOn ? .tintColor : .label
        button.configuration = config
        button.isSelected = isOn
        button.accessibilityTraits = isOn ? [.button, .selected] : .button
        button.accessibilityHint = clears ? String(localized: "Shows everything again") : nil
    }

    /// Scrolls the row just far enough that the lit chip sits fully inside it.
    private func revealSelectedChip(animated: Bool) {
        guard let capsule = chips.first(where: { $0.filter == selected })?.capsule else { return }
        scrollView.layoutIfNeeded()
        stack.layoutIfNeeded()
        let inset = scrollView.adjustedContentInset
        let width = scrollView.bounds.width
        let lowest = -inset.left
        let highest = max(lowest, scrollView.contentSize.width + inset.right - width)
        var x = scrollView.contentOffset.x
        if capsule.frame.minX - inset.left < x {
            x = capsule.frame.minX - inset.left
        } else if capsule.frame.maxX + inset.right > x + width {
            x = capsule.frame.maxX + inset.right - width
        }
        x = min(max(x, lowest), highest)
        guard x != scrollView.contentOffset.x else { return }
        scrollView.setContentOffset(CGPoint(x: x, y: scrollView.contentOffset.y), animated: animated)
    }
}
