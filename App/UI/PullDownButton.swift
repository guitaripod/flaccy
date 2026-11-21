import UIKit

extension UIButton {

    /// Sizes a pull-down's button to its title on one line, never wider than `maxWidth`.
    /// A table row's accessory is not stretched by Auto Layout, so a button measured
    /// against its previous, narrower bounds would break its title letter by letter.
    func fitToPullDownTitle(maxWidth: CGFloat = .greatestFiniteMagnitude) {
        configuration?.titleLineBreakMode = .byTruncatingTail
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let natural = systemLayoutSizeFitting(unbounded, withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .fittingSizeLevel)
        let wide = sizeThatFits(unbounded)
        let width = min(max(natural.width, wide.width), maxWidth)
        let height = max(natural.height, wide.height)
        bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
    }
}
