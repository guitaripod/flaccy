import UIKit

/// How much of a header that rides above a list is tucked away under the bar.
/// It leaves with the list on the way down and comes back on any move up, and
/// never hides more than the list has travelled from its top.
nonisolated struct HeaderCollapse: Equatable {

    private(set) var hidden: CGFloat = 0
    private var isReturning = false

    mutating func follow(delta: CGFloat, distanceFromTop: CGFloat, height: CGFloat) {
        if delta != 0 { isReturning = delta < 0 }
        hidden = max(min(hidden + delta, height, max(distanceFromTop, 0)), 0)
    }

    /// Ends a half-shown header once the list rests: open when the last move
    /// was back up or the list is too near its top to cover the gap, shut
    /// otherwise.
    mutating func settle(distanceFromTop: CGFloat, height: CGFloat) {
        guard hidden > 0, hidden < height else { return }
        hidden = isReturning || distanceFromTop < height ? 0 : height
    }

    mutating func reveal() {
        hidden = 0
    }
}

/// Controls that sit between the navigation bar and a list, over the list
/// rather than above it: the list runs underneath to the top of the screen,
/// the header slides away as it scrolls down and returns on the first move
/// back up. Arrange the controls in `stack`; the list's top inset follows the
/// stack's height.
final class CollapsingHeaderView: UIView {

    let stack = UIStackView()

    /// Called with the header's full height whenever its contents change it.
    var onHeightChange: ((CGFloat) -> Void)?

    private(set) var fullHeight: CGFloat = 0
    private weak var scrollView: UIScrollView?
    private var collapse = HeaderCollapse()
    private var lastOffset: CGFloat?
    private lazy var visibleHeight = heightAnchor.constraint(equalToConstant: 0)
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))

    init(following scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            visibleHeight,
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverDidChange), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installBackdrop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let measured = stack.bounds.height
        guard abs(measured - fullHeight) > 0.5 else { return }
        adopt(height: measured)
    }

    /// Call from `scrollViewDidScroll`.
    func listDidScroll() {
        guard let scrollView else { return }
        let offset = scrollView.contentOffset.y
        let previous = lastOffset ?? offset
        lastOffset = offset
        let distance = distanceFromTop(of: scrollView)
        updateBackdrop(distanceFromTop: distance)
        guard !UIAccessibility.isVoiceOverRunning else { return }
        let end = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        let byHand = scrollView.isTracking || scrollView.isDecelerating
        let delta = byHand && offset <= end && previous <= end ? offset - previous : 0
        let before = collapse
        collapse.follow(delta: delta, distanceFromTop: distance, height: fullHeight)
        if collapse != before { apply() }
    }

    /// Call when a drag ends without momentum and when momentum runs out.
    func listDidRest() {
        guard let scrollView else { return }
        let before = collapse
        collapse.settle(distanceFromTop: distanceFromTop(of: scrollView), height: fullHeight)
        guard collapse != before else { return }
        applyAnimated()
    }

    func reveal(animated: Bool) {
        guard collapse.hidden > 0 else { return }
        collapse.reveal()
        if animated { applyAnimated() } else { apply() }
    }

    @objc private func voiceOverDidChange() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        reveal(animated: false)
    }

    private func distanceFromTop(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    }

    /// Makes room for a header that grew or shrank. A list resting at its top
    /// stays there; one scrolled further keeps its place under the header.
    private func adopt(height: CGFloat) {
        fullHeight = height
        if let scrollView {
            let restsAtTop = distanceFromTop(of: scrollView) <= 0.5
            lastOffset = nil
            scrollView.contentInset.top = height
            if restsAtTop {
                collapse.reveal()
                scrollView.contentOffset.y = -scrollView.adjustedContentInset.top
            } else {
                collapse.follow(delta: 0, distanceFromTop: distanceFromTop(of: scrollView), height: height)
            }
            lastOffset = scrollView.contentOffset.y
        }
        apply()
        onHeightChange?(height)
    }

    private func apply() {
        let visible = max(fullHeight - collapse.hidden, 0)
        if visibleHeight.constant != visible { visibleHeight.constant = visible }
        scrollView?.verticalScrollIndicatorInsets.top = visible
        if let scrollView { updateBackdrop(distanceFromTop: distanceFromTop(of: scrollView)) }
    }

    private func applyAnimated() {
        apply()
        guard !UIAccessibility.isReduceMotionEnabled, window != nil else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.superview?.layoutIfNeeded()
        }
    }

    /// What keeps the list readable where it passes under the controls: the
    /// bar's material from the top of the screen to a hairline under the
    /// header, so bar and header read as one surface. It sits behind the header
    /// in the header's superview, because the header clips at the bar. The
    /// system's scroll edge effect is not extended over the header instead: its
    /// fade reaches some 40 pt past the header and washed out the first row of
    /// a list at rest.
    private func installBackdrop() {
        backdrop.removeFromSuperview()
        guard let superview else { return }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.alpha = 0
        backdrop.isUserInteractionEnabled = false
        if backdrop.contentView.subviews.isEmpty {
            let hairline = HairlineView(color: .separator)
            backdrop.contentView.addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor),
                hairline.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor),
            ])
        }
        superview.insertSubview(backdrop, belowSubview: self)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: superview.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Shows the backdrop once the list has left its top, and lets it go with
    /// the header so a collapsed header leaves only the bar's own edge effect.
    private func updateBackdrop(distanceFromTop distance: CGFloat) {
        let shown = fullHeight > 0 ? max(fullHeight - collapse.hidden, 0) / fullHeight : 0
        backdrop.alpha = min(max(distance / 12, 0), 1) * shown
    }
}
