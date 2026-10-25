import UIKit

/// A rule one device pixel thick. Its thickness follows the display scale of
/// the screen it is on, read from its own traits so it stays right when the
/// window moves between an iPhone Duo's two displays.
final class HairlineView: UIView {

    private static let fallbackScale: CGFloat = 3

    private lazy var thickness = heightAnchor.constraint(equalToConstant: 1 / Self.fallbackScale)

    init(color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = color
        translatesAutoresizingMaskIntoConstraints = false
        thickness.isActive = true
        isAccessibilityElement = false
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in self.applyDisplayScale() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayScale()
    }

    /// Sets the height to one pixel at the scale of the screen showing this view.
    private func applyDisplayScale() {
        let scale = traitCollection.displayScale
        thickness.constant = 1 / (scale > 0 ? scale : Self.fallbackScale)
    }
}
